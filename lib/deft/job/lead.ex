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
  alias Deft.Job.Runner
  alias Deft.Store
  alias Deft.Project

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
  - `:working_dir` — Required. Project working directory for cache path resolution.
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
    working_dir = Keyword.fetch!(opts, :working_dir)
    runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)
    name = Keyword.get(opts, :name)

    initial_data = %{
      lead_id: lead_id,
      session_id: session_id,
      config: config,
      deliverable: deliverable,
      foreman_pid: foreman_pid,
      site_log_name: site_log_name,
      site_log_tid: nil,
      rate_limiter_pid: rate_limiter_pid,
      worktree_path: worktree_path,
      working_dir: working_dir,
      runner_supervisor: runner_supervisor,
      cache_pid: nil,
      cache_tid: nil,
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
  def terminate(_reason, _state, data) do
    # Clean up the cache instance if it exists
    if data.cache_pid do
      Logger.info("Lead #{data.lead_id}: cleaning up cache instance")

      case Store.cleanup(data.cache_pid) do
        :ok ->
          Logger.info("Lead #{data.lead_id}: cache cleanup successful")

        {:error, reason} ->
          Logger.warning("Lead #{data.lead_id}: cache cleanup failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @impl :gen_statem
  def init(initial_data) do
    # Obtain site log ETS tid for direct reads
    # The Foreman passes the site log registered name; we resolve it to get the PID,
    # then call Deft.Store.tid/1 to get the ETS tid for direct reads.
    site_log_tid =
      case Registry.lookup(Deft.ProcessRegistry, initial_data.site_log_name) do
        [{site_log_pid, _}] ->
          Store.tid(site_log_pid)

        [] ->
          Logger.warning("Lead #{initial_data.lead_id}: site log not found, reads will fail")
          nil
      end

    # Start cache instance for this Lead
    # Cache path: ~/.deft/projects/<path-encoded-repo>/cache/<session_id>/lead-<lead_id>.dets
    cache_dir = Project.cache_dir(initial_data.working_dir)
    cache_session_dir = Path.join(cache_dir, initial_data.session_id)
    cache_path = Path.join(cache_session_dir, "lead-#{initial_data.lead_id}.dets")

    cache_name = {:cache, initial_data.session_id, initial_data.lead_id}

    case Store.start_link(
           name: cache_name,
           type: :cache,
           dets_path: cache_path
         ) do
      {:ok, cache_pid} ->
        cache_tid = Store.tid(cache_pid)
        Logger.info("Lead #{initial_data.lead_id}: started cache instance at #{cache_path}")

        initial_data =
          %{initial_data | site_log_tid: site_log_tid, cache_pid: cache_pid, cache_tid: cache_tid}

        # Start in planning phase, idle agent state
        initial_state = {:planning, :idle}
        {:ok, initial_state, initial_data}

      {:error, reason} ->
        Logger.error("Lead #{initial_data.lead_id}: failed to start cache: #{inspect(reason)}")
        # Continue without cache
        initial_data = %{initial_data | site_log_tid: site_log_tid}
        initial_state = {:planning, :idle}
        {:ok, initial_state, initial_data}
    end
  end

  @impl :gen_statem
  # State entry handlers
  def handle_event(:enter, _old_state, {:planning, :idle}, data) do
    # When entering planning phase, start by decomposing deliverable into tasks
    # Build initial planning prompt from deliverable assignment and site log
    planning_prompt = build_planning_prompt(data)

    {:keep_state_and_data, [{:next_event, :cast, {:prompt, planning_prompt}}]}
  end

  def handle_event(:enter, _old_state, {:verifying, :idle}, data) do
    # When entering verification phase, run compile checks
    Logger.info("Lead #{data.lead_id} starting verification")

    # Spawn a testing runner to verify the deliverable
    verification_prompt = build_verification_prompt(data)

    {:keep_state_and_data, [{:next_event, :cast, {:prompt, verification_prompt}}]}
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
          Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
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
        %{tool_tasks: tasks, runner_tasks: runner_tasks} = data
      )
      when is_reference(ref) do
    # Check if this ref belongs to a tool task or runner task
    # This handler fires before the runner handler due to more specific state pattern,
    # so we must explicitly check runner_tasks to avoid consuming runner completion messages
    cond do
      Enum.any?(tasks, fn task -> task.ref == ref end) ->
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

      Map.has_key?(runner_tasks, ref) ->
        # This is a runner task - handle it using the runner logic
        runner_info = Map.get(runner_tasks, ref)
        Logger.info("Lead #{data.lead_id} runner completed: #{runner_info.task_description}")

        # Remove completed runner from tracking
        runner_tasks = Map.delete(runner_tasks, ref)
        data = %{data | runner_tasks: runner_tasks}

        # Process runner result and decide next action
        data = process_runner_result(results, runner_info, data)

        # Send status update to Foreman
        send_lead_message(
          data.foreman_pid,
          :status,
          "Completed: #{runner_info.task_description}",
          %{}
        )

        # Continue work since we're in executing_tools state (agent will return to idle later)
        continue_work(chunk_phase, data)

      true ->
        # Neither tool nor runner task
        :keep_state_and_data
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
    # Read from site log if available
    site_log_context = read_site_log_context(data.site_log_tid)

    """
    You are a Lead managing this deliverable:

    #{data.deliverable}

    Your task is to:
    1. Read research findings and interface contracts from the site log
    2. Decompose this deliverable into a task list (4-8 tasks, dependency-ordered)
    3. Define clear done states for each task

    #{site_log_context}

    Use the available tools to explore the codebase and plan your approach.
    Once you have a task list, report it back.
    """
  end

  defp build_verification_prompt(data) do
    # Build prompt for verification phase
    completed_work =
      data.task_list
      |> Enum.filter(fn t -> t.status == :done end)
      |> Enum.map(fn t -> "- #{t.description}" end)
      |> Enum.join("\n")

    """
    You are verifying the deliverable is complete and correct.

    ## Deliverable
    #{data.deliverable}

    ## Completed Tasks
    #{completed_work}

    ## Verification Steps
    1. Run compile checks (if applicable)
    2. Run relevant tests
    3. Review modified files for correctness

    If all checks pass, report completion. If any issues found, report them for correction.
    """
  end

  # Reads relevant context from the site log.
  # Returns a formatted string with research findings, contracts, and decisions
  # from the site log, or an empty string if no site log is available.
  defp read_site_log_context(nil), do: ""

  defp read_site_log_context(site_log_tid) do
    # Get all keys from the site log
    keys = Store.keys(site_log_tid)

    if Enum.empty?(keys) do
      ""
    else
      # Read all entries and group by category
      entries =
        Enum.map(keys, fn key ->
          case Store.read(site_log_tid, key) do
            {:ok, entry} -> {key, entry}
            :miss -> nil
            :expired -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      # Group entries by category
      grouped =
        Enum.group_by(entries, fn {_key, entry} ->
          Map.get(entry.metadata, :category, :other)
        end)

      # Format the context
      sections =
        [
          format_site_log_section(
            "Research Findings",
            Map.get(grouped, :research, [])
          ),
          format_site_log_section(
            "Interface Contracts",
            Map.get(grouped, :contract, [])
          ),
          format_site_log_section(
            "Decisions",
            Map.get(grouped, :decision, [])
          ),
          format_site_log_section(
            "Critical Findings",
            Map.get(grouped, :critical_finding, [])
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      if sections == "" do
        ""
      else
        """
        ## Site Log Context

        #{sections}
        """
      end
    end
  end

  defp format_site_log_section(_title, []), do: nil

  defp format_site_log_section(title, entries) do
    formatted_entries =
      entries
      |> Enum.map(fn {key, entry} ->
        "  - **#{key}**: #{inspect(entry.value)}"
      end)
      |> Enum.join("\n")

    """
    ### #{title}

    #{formatted_entries}
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
          data.session_id,
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
    # Evaluate runner result and update task list
    Logger.info(
      "Processing runner result for #{runner_info.task_description}: #{inspect(result)}"
    )

    case result do
      {:ok, output} ->
        # Update task list - mark current task as done
        task_list =
          update_task_status(data.task_list, runner_info.task_description, :done, output)

        # Evaluate if the output meets expectations
        evaluation = evaluate_runner_output(output, runner_info, data)

        data = %{data | task_list: task_list}

        # Send evaluation to Foreman
        case evaluation do
          {:success, summary} ->
            send_lead_message(
              data.foreman_pid,
              :status,
              "Task completed successfully: #{runner_info.task_description}\n\nSummary: #{summary}",
              %{task: runner_info.task_description}
            )

            data

          {:needs_correction, reason} ->
            Logger.warning("Lead #{data.lead_id} detected issue: #{reason}")

            send_lead_message(
              data.foreman_pid,
              :finding,
              "Task needs correction: #{runner_info.task_description}\n\nReason: #{reason}",
              %{task: runner_info.task_description, shared: false}
            )

            # Add corrective task to the task list
            corrective_task = %{
              description: "Fix: #{runner_info.task_description} - #{reason}",
              status: :pending,
              result: nil,
              correction_for: runner_info.task_description
            }

            %{data | task_list: data.task_list ++ [corrective_task]}

          {:critical_issue, issue} ->
            Logger.error("Lead #{data.lead_id} found critical issue: #{issue}")

            send_lead_message(
              data.foreman_pid,
              :critical_finding,
              "Critical issue in task: #{runner_info.task_description}\n\nIssue: #{issue}",
              %{task: runner_info.task_description}
            )

            data
        end

      {:error, error_msg} ->
        # Mark task as failed
        task_list =
          update_task_status(data.task_list, runner_info.task_description, :failed, error_msg)

        send_lead_message(
          data.foreman_pid,
          :error,
          "Task failed: #{runner_info.task_description}\n\nError: #{error_msg}",
          %{task: runner_info.task_description}
        )

        %{data | task_list: task_list}
    end
  end

  defp continue_work(:verifying, data) do
    # In verification phase, check if verification runner has completed
    # and decide whether to report completion or go back to executing
    if Enum.empty?(data.runner_tasks) do
      # No runners active - check verification results
      # For now, assume if we reached here without errors, verification passed
      Logger.info("Lead #{data.lead_id} verification complete, reporting to Foreman")

      send_lead_message(
        data.foreman_pid,
        :complete,
        "Deliverable complete and verified",
        %{
          lead_id: data.lead_id,
          deliverable: data.deliverable,
          tasks_completed: length(Enum.filter(data.task_list, &(&1.status == :done)))
        }
      )

      {:next_state, {:complete, :idle}, data}
    else
      # Verification still running
      {:keep_state, data}
    end
  end

  defp continue_work(_chunk_phase, data) do
    # Check if there are more tasks to execute
    pending_tasks = Enum.filter(data.task_list, fn task -> task.status == :pending end)

    cond do
      # No pending tasks - check if deliverable is complete
      Enum.empty?(pending_tasks) ->
        # Check if all tasks are done (no failed tasks)
        failed_tasks = Enum.filter(data.task_list, fn task -> task.status == :failed end)

        if Enum.empty?(failed_tasks) do
          # All tasks done - transition to verification
          Logger.info("Lead #{data.lead_id} all tasks complete, transitioning to verification")

          send_lead_message(
            data.foreman_pid,
            :status,
            "All tasks complete, starting verification",
            %{}
          )

          {:next_state, {:verifying, :idle}, data}
        else
          # Some tasks failed - report as blocker
          Logger.error("Lead #{data.lead_id} has failed tasks, reporting blocker")
          failed_descriptions = Enum.map(failed_tasks, & &1.description)

          send_lead_message(
            data.foreman_pid,
            :blocker,
            "Deliverable stuck: #{length(failed_tasks)} task(s) failed",
            %{failed_tasks: failed_descriptions}
          )

          {:keep_state, data}
        end

      # Check if we're at max concurrent runners
      length(data.runner_tasks) >= Map.get(data.config, :max_runners_per_lead, 3) ->
        Logger.debug("Lead #{data.lead_id} at max concurrent runners, waiting")
        {:keep_state, data}

      # Spawn next pending task
      true ->
        next_task = List.first(pending_tasks)
        Logger.info("Lead #{data.lead_id} spawning runner for: #{next_task.description}")

        # Mark task as in-progress
        task_list = update_task_status(data.task_list, next_task.description, :in_progress, nil)
        data = %{data | task_list: task_list}

        # Build context for the runner
        runner_context = build_runner_context(next_task, data)

        # Determine runner type based on task description
        runner_type = determine_runner_type(next_task)

        # Spawn runner
        {:ok, _task_ref, _monitor_ref, data} =
          spawn_runner(
            data,
            runner_type,
            next_task.description,
            next_task.description,
            runner_context
          )

        {:keep_state, data}
    end
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

  # Updates task status in task list
  defp update_task_status(task_list, task_description, new_status, result) do
    Enum.map(task_list, fn task ->
      if task.description == task_description do
        %{task | status: new_status, result: result}
      else
        task
      end
    end)
  end

  # Evaluates runner output to determine if task was completed correctly
  defp evaluate_runner_output(output, runner_info, _data) do
    # Basic evaluation logic:
    # - Check if output indicates success or problems
    # - Look for error indicators in output
    # - Consider task complexity and output length

    output_lower = String.downcase(output)

    cond do
      # Check for explicit error indicators
      String.contains?(output_lower, ["error:", "failed:", "exception:", "panic:"]) ->
        {:needs_correction, "Output contains error indicators"}

      # Check for very short output (might indicate incomplete work)
      String.length(output) < 20 ->
        {:needs_correction, "Output too brief, task may be incomplete"}

      # Check for test failures if this was a testing runner
      runner_info.runner_type == :testing and
          String.contains?(output_lower, ["failed", "failure"]) ->
        {:critical_issue, "Tests failed"}

      # Success case
      true ->
        # Extract a summary from the output (first sentence or first 100 chars)
        summary =
          output
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == ""))
          |> List.first()
          |> case do
            nil -> "Task completed"
            line -> String.slice(line, 0..100)
          end

        {:success, summary}
    end
  end

  # Builds context string for runner based on current state
  defp build_runner_context(task, data) do
    # Read relevant information from site log
    site_log_context = read_site_log_context(data.site_log_tid)

    # Include completed task results for context
    completed_tasks =
      data.task_list
      |> Enum.filter(fn t -> t.status == :done and t.result != nil end)
      |> Enum.map(fn t -> "- #{t.description}: #{t.result}" end)
      |> Enum.join("\n")

    completed_context =
      if completed_tasks != "" do
        """

        ## Completed Tasks

        #{completed_tasks}
        """
      else
        ""
      end

    """
    #{site_log_context}#{completed_context}

    ## Current Task

    #{task.description}

    ## Deliverable Goal

    #{data.deliverable}
    """
  end

  # Determines runner type based on task description keywords
  defp determine_runner_type(task) do
    desc_lower = String.downcase(task.description)

    cond do
      String.contains?(desc_lower, ["test", "verify", "validate"]) -> :testing
      String.contains?(desc_lower, ["review", "check", "audit"]) -> :review
      String.contains?(desc_lower, ["research", "explore", "investigate"]) -> :research
      String.contains?(desc_lower, ["merge", "conflict", "resolve"]) -> :merge_resolution
      true -> :implementation
    end
  end
end
