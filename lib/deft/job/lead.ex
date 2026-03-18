defmodule Deft.Job.Lead do
  @moduledoc """
  Lead manages a single deliverable using a gen_statem with tuple states.

  The Lead IS the Agent extended with chunk management states. State format:
  `{chunk_phase, agent_state}` where chunk_phase tracks the deliverable lifecycle
  and agent_state tracks the agent loop state (:idle, :calling, :streaming, :executing_tools).

  ## Chunk Phases

  - `:planning` — Receives assignment, reads research, decomposes into task list
  - `:executing` — Spawns Runners, evaluates output, steers
  - `:verifying` — Runs compile checks, validates deliverable
  - `:complete` — Signals completion to Foreman

  ## Foreman Steering

  The Lead handles `{:foreman_steering, content}` messages from the Foreman
  in any state using handle_event fallback.

  ## Active Steering

  The Lead is a pair-programming manager:
  - Plans tasks with rich context
  - Spawns Runners with detailed instructions
  - Evaluates Runner output
  - Spawns corrective Runners if needed
  - Updates task list
  - Runs compile checks after each Runner
  - Sends progress messages to Foreman

  ## Runner Management

  Runners are spawned via `Task.Supervisor.async_nolink`. The Lead MUST explicitly
  monitor each Runner task via `Process.monitor(task.pid)` since async_nolink
  does not auto-link.
  """

  @behaviour :gen_statem

  alias Deft.Message
  alias Deft.Agent.ToolRunner
  alias Deft.Job.Runner

  require Logger

  # Client API

  @doc """
  Starts the Lead gen_statem.

  ## Options

  - `:lead_id` — Required. Unique identifier for this Lead.
  - `:session_id` — Required. Job session identifier.
  - `:config` — Required. Configuration map.
  - `:deliverable` — Required. Deliverable assignment (text description).
  - `:foreman_pid` — Required. PID of the Foreman for messaging.
  - `:site_log_name` — Required. Registered name of Deft.Store site log instance.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:worktree_path` — Required. Path to Lead's git worktree.
  - `:runner_supervisor` — Required. Name of the Lead's Task.Supervisor for Runners.
  - `:name` — Optional. Name for the gen_statem process.
  """
  def start_link(opts) do
    lead_id = Keyword.fetch!(opts, :lead_id)
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    deliverable = Keyword.fetch!(opts, :deliverable)
    foreman_pid = Keyword.fetch!(opts, :foreman_pid)
    site_log_name = Keyword.fetch!(opts, :site_log_name)
    rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
    worktree_path = Keyword.fetch!(opts, :worktree_path)
    runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)
    name = Keyword.get(opts, :name)

    initial_data = %{
      lead_id: lead_id,
      session_id: session_id,
      config: config,
      deliverable: deliverable,
      foreman_pid: foreman_pid,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid,
      worktree_path: worktree_path,
      runner_supervisor: runner_supervisor,
      messages: [],
      task_list: [],
      runner_tasks: %{},
      current_message: nil,
      stream_ref: nil,
      stream_monitor_ref: nil,
      tool_tasks: [],
      tool_call_buffers: %{},
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Returns child spec with restart: :temporary.

  The Foreman handles Lead crash recovery explicitly, so Leads should not
  be automatically restarted by their supervisor.
  """
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :lead_id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Sends a prompt to the Lead.
  """
  def prompt(lead, text) do
    :gen_statem.cast(lead, {:prompt, text})
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(initial_data) do
    # Start in planning phase, idle agent state
    initial_state = {:planning, :idle}
    {:ok, initial_state, initial_data}
  end

  @impl :gen_statem
  # State entry handlers
  def handle_event(:enter, _old_state, {:planning, :idle}, data) do
    # When entering planning phase, start by decomposing deliverable into tasks
    # Build initial planning prompt from deliverable assignment and site log
    planning_prompt = build_planning_prompt(data)

    {:keep_state_and_data, [{:next_event, :cast, {:prompt, planning_prompt}}]}
  end

  def handle_event(:enter, _old_state, {chunk_phase, :executing_tools}, data) do
    # Extract tool calls from the last assistant message
    tool_calls = extract_tool_calls(data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls - return to idle in current chunk phase
      {:next_state, {chunk_phase, :idle}, data}
    else
      # Execute tools
      tasks =
        Enum.map(tool_calls, fn tool_call ->
          Task.Supervisor.async_nolink(ToolRunner, fn ->
            execute_tool(tool_call, data)
          end)
        end)

      {:keep_state, %{data | tool_tasks: tasks}}
    end
  end

  def handle_event(:enter, _old_state, _state, _data) do
    :keep_state_and_data
  end

  # Prompt handling
  def handle_event(:cast, {:prompt, text}, {chunk_phase, :idle}, data) do
    # Add user message to conversation
    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Deft.Message.Text{text: text}],
      timestamp: DateTime.utc_now()
    }

    messages = data.messages ++ [user_message]

    # Start LLM call
    data = %{data | messages: messages, turn_count: data.turn_count + 1}
    {:ok, stream_ref, monitor_ref} = call_llm(data)
    data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
    {:next_state, {chunk_phase, :calling}, data}
  end

  # Foreman steering (works in any state)
  def handle_event(:info, {:foreman_steering, content}, {chunk_phase, agent_state}, data) do
    Logger.info("Lead #{data.lead_id} received steering from Foreman")

    # Add steering as a user message
    steering_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Deft.Message.Text{text: "[FOREMAN STEERING]\n#{content}"}],
      timestamp: DateTime.utc_now()
    }

    messages = data.messages ++ [steering_message]
    data = %{data | messages: messages}

    # If idle, start processing the steering
    if agent_state == :idle do
      {:ok, stream_ref, monitor_ref} = call_llm(data)
      data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
      {:next_state, {chunk_phase, :calling}, data}
    else
      # Not idle - queue the steering for next idle state
      {:keep_state, data}
    end
  end

  # Provider event handling during streaming
  def handle_event(:info, {:provider_event, event}, {chunk_phase, :calling}, data) do
    # First event received - transition to streaming
    data = process_provider_event(event, data)
    {:next_state, {chunk_phase, :streaming}, data}
  end

  def handle_event(:info, {:provider_event, event}, {chunk_phase, :streaming}, data) do
    data = process_provider_event(event, data)

    # Check if streaming is done
    if done_streaming?(event) do
      # Finalize message and transition to executing_tools
      data = finalize_streaming(data)
      {:next_state, {chunk_phase, :executing_tools}, data}
    else
      {:keep_state, data}
    end
  end

  # Tool task completion (Lead's own tool tasks, not Runner tasks)
  def handle_event(
        :info,
        {ref, results},
        {chunk_phase, :executing_tools},
        %{tool_tasks: tasks} = data
      )
      when is_reference(ref) do
    # A tool task completed
    tasks = Enum.reject(tasks, fn task -> task.ref == ref end)
    data = %{data | tool_tasks: tasks}

    # Add tool results to messages
    data = add_tool_results(results, data)

    # If all tasks done, loop back to call LLM or check for continuation
    if Enum.empty?(tasks) do
      if should_continue_turn?(data) do
        # Make another LLM call
        {:ok, stream_ref, monitor_ref} = call_llm(data)
        data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
        {:next_state, {chunk_phase, :calling}, data}
      else
        {:next_state, {chunk_phase, :idle}, data}
      end
    else
      {:keep_state, data}
    end
  end

  # Runner task completion
  def handle_event(
        :info,
        {ref, runner_result},
        {chunk_phase, agent_state},
        %{runner_tasks: runner_tasks} = data
      )
      when is_reference(ref) do
    # Find the completed runner task
    case Map.get(runner_tasks, ref) do
      nil ->
        # Not a runner task reference, ignore
        :keep_state_and_data

      runner_info ->
        Logger.info("Lead #{data.lead_id} runner completed: #{runner_info.task_description}")

        # Remove completed runner from tracking
        runner_tasks = Map.delete(runner_tasks, ref)
        data = %{data | runner_tasks: runner_tasks}

        # Process runner result and decide next action
        data = process_runner_result(runner_result, runner_info, data)

        # Send status update to Foreman
        send_lead_message(
          data.foreman_pid,
          :status,
          "Completed: #{runner_info.task_description}",
          %{}
        )

        # If agent is idle, resume work
        if agent_state == :idle do
          # Continue with next task or complete deliverable
          continue_work(chunk_phase, data)
        else
          {:keep_state, data}
        end
    end
  end

  # Runner task crash (DOWN message)
  def handle_event(
        :info,
        {:DOWN, monitor_ref, :process, _pid, reason},
        {chunk_phase, agent_state},
        %{runner_tasks: runner_tasks} = data
      ) do
    # Find crashed runner by monitor ref
    crashed_runner =
      Enum.find(runner_tasks, fn {_task_ref, info} ->
        info.monitor_ref == monitor_ref
      end)

    case crashed_runner do
      nil ->
        # Not a runner monitor, ignore
        :keep_state_and_data

      {task_ref, runner_info} ->
        Logger.error(
          "Lead #{data.lead_id} runner crashed: #{runner_info.task_description}, reason: #{inspect(reason)}"
        )

        # Remove crashed runner
        runner_tasks = Map.delete(runner_tasks, task_ref)
        data = %{data | runner_tasks: runner_tasks}

        # Send error to Foreman
        send_lead_message(
          data.foreman_pid,
          :error,
          "Runner crashed: #{runner_info.task_description}",
          %{reason: inspect(reason)}
        )

        # If agent is idle, resume work (potentially retry or skip)
        if agent_state == :idle do
          continue_work(chunk_phase, data)
        else
          {:keep_state, data}
        end
    end
  end

  # Catch-all for unhandled events
  def handle_event(event_type, event_content, state, _data) do
    Logger.debug(
      "Unhandled event: #{event_type} #{inspect(event_content)} in state #{inspect(state)}"
    )

    :keep_state_and_data
  end

  # Private helpers

  defp build_planning_prompt(data) do
    """
    You are a Lead managing this deliverable:

    #{data.deliverable}

    Your task is to:
    1. Read research findings and interface contracts from the site log
    2. Decompose this deliverable into a task list (4-8 tasks, dependency-ordered)
    3. Define clear done states for each task

    Use the available tools to explore the codebase and plan your approach.
    Once you have a task list, report it back.
    """
  end

  defp extract_tool_calls(messages) do
    case List.last(messages) do
      %Message{role: :assistant, content: content} ->
        Enum.filter(content, fn
          %Deft.Message.ToolUse{} -> true
          _ -> false
        end)

      _ ->
        []
    end
  end

  defp execute_tool(tool_call, _data) do
    # Placeholder for tool execution
    Logger.debug("Lead executing tool: #{tool_call.name}")
    {:ok, "Tool result placeholder"}
  end

  defp call_llm(_data) do
    # Placeholder for LLM call
    Logger.debug("Lead calling LLM")
    {:ok, make_ref(), make_ref()}
  end

  defp process_provider_event(_event, data) do
    # Placeholder for processing provider events
    data
  end

  defp done_streaming?(event) do
    # Check if this is a Done event
    match?(%Deft.Provider.Event.Done{}, event)
  end

  defp finalize_streaming(data) do
    # Finalize the current message and add to messages list
    # Placeholder implementation
    data
  end

  defp add_tool_results(_results, data) do
    # Add tool results to the messages
    # Placeholder implementation
    data
  end

  defp should_continue_turn?(data) do
    # Check turn limit
    max_turns = Map.get(data.config, :max_turns, 25)
    data.turn_count < max_turns
  end

  @doc """
  Spawns a Runner task via Task.Supervisor.async_nolink and monitors it.

  Returns: {:ok, task_ref, monitor_ref}
  """
  def spawn_runner(data, runner_type, task_description, instructions, context) do
    # Spawn Runner via async_nolink
    task =
      Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
        Runner.run(
          runner_type,
          instructions,
          context,
          data.rate_limiter_pid,
          data.config,
          data.worktree_path
        )
      end)

    # CRITICAL: Must explicitly monitor since we used async_nolink
    monitor_ref = Process.monitor(task.pid)

    # Store runner info for tracking
    runner_info = %{
      task_description: task_description,
      runner_type: runner_type,
      monitor_ref: monitor_ref,
      started_at: System.monotonic_time(:millisecond)
    }

    runner_tasks = Map.put(data.runner_tasks, task.ref, runner_info)
    data = %{data | runner_tasks: runner_tasks}

    Logger.info("Lead #{data.lead_id} spawned runner: #{task_description}")

    {:ok, task.ref, monitor_ref, data}
  end

  defp process_runner_result(result, runner_info, data) do
    # Placeholder for processing runner results
    # In real implementation:
    # - Evaluate if the task was completed correctly
    # - Update task list
    # - Decide if corrective action needed
    # - Send findings/decisions to Foreman
    Logger.debug(
      "Processing runner result for #{runner_info.task_description}: #{inspect(result)}"
    )

    data
  end

  defp continue_work(chunk_phase, data) do
    # Placeholder for continuing work after runner completion
    # In real implementation:
    # - Check if more tasks remain
    # - Spawn next runner
    # - Or transition to verification/complete phase
    Logger.debug("Lead #{data.lead_id} continuing work in #{chunk_phase}")
    {:keep_state, data}
  end

  @doc """
  Sends a message to the Foreman.

  Message format: `{:lead_message, type, content, metadata}`

  Types: :status, :decision, :artifact, :contract, :contract_revision,
         :plan_amendment, :complete, :blocker, :error, :critical_finding, :finding
  """
  def send_lead_message(foreman_pid, type, content, metadata) do
    send(foreman_pid, {:lead_message, type, content, metadata})
  end

  defp generate_message_id do
    "msg_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
  end
end
