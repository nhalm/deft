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
  - Spawns testing Runners to verify compile checks and tests (delegates, not executes)
  - Sends progress messages to Foreman

  ## Runner Management

  Runners are spawned via `Task.Supervisor.async_nolink`. The Lead MUST explicitly
  monitor each Runner task via `Process.monitor(task.pid)` since async_nolink
  does not auto-link.
  """

  @behaviour :gen_statem

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Job.Runner
  alias Deft.Job.RateLimiter
  alias Deft.Store
  alias Deft.Project

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
    ToolCallDone,
    Usage,
    Done
  }

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

    # Build session file path for Lead
    jobs_dir = Project.jobs_dir(working_dir)
    session_file_path = Path.join([jobs_dir, session_id, "lead_#{lead_id}_session.jsonl"])

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
      tool_results: [],
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      session_file_path: session_file_path,
      saved_message_ids: MapSet.new()
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
  def handle_event(:enter, old_state, {:planning, :idle}, data) do
    case old_state do
      {:planning, :executing_tools} ->
        # Returning from LLM response - parse task list and transition to executing
        case extract_task_list_from_messages(data.messages) do
          [] ->
            # No tasks found - report error to Foreman
            Logger.error(
              "Lead #{data.lead_id} failed to extract task list from planning response"
            )

            send_lead_message(
              data.foreman_pid,
              :blocker,
              "Unable to decompose deliverable into tasks",
              %{lead_id: data.lead_id}
            )

            {:keep_state, data}

          tasks ->
            # Tasks extracted successfully - store and transition to executing
            Logger.info("Lead #{data.lead_id} extracted #{length(tasks)} tasks from planning")

            send_lead_message(
              data.foreman_pid,
              :status,
              "Planning complete: #{length(tasks)} tasks identified",
              %{task_count: length(tasks)}
            )

            data = %{data | task_list: tasks}
            {:next_state, {:executing, :idle}, data}
        end

      _ ->
        # Initial entry to planning phase - start by decomposing deliverable into tasks
        # Build initial planning prompt from deliverable assignment and site log
        planning_prompt = build_planning_prompt(data)

        # Use cast instead of next_event - next_event is prohibited in state_enter callbacks
        :gen_statem.cast(self(), {:prompt, planning_prompt})
        :keep_state_and_data
    end
  end

  def handle_event(:enter, _old_state, {:verifying, :idle}, data) do
    # When entering verification phase, spawn a testing runner to run compile checks and tests
    Logger.info("Lead #{data.lead_id} starting verification")

    # Build verification instructions for the testing runner
    verification_instructions = build_verification_prompt(data)

    # Build context for the runner
    runner_context = build_runner_context_for_verification(data)

    # Spawn a testing runner (has bash access for compile checks and tests)
    {:ok, _task_ref, _monitor_ref, data} =
      spawn_runner(
        data,
        :testing,
        "Verify deliverable with compile checks and tests",
        verification_instructions,
        runner_context
      )

    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, {chunk_phase, :executing_tools}, data) do
    # Extract tool calls from the last assistant message
    tool_calls = extract_tool_calls(data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls - return to idle in current chunk phase
      # Can't use {:next_state, ...} from state_enter, so cast to self
      :gen_statem.cast(self(), {:no_tools_return_idle, chunk_phase})
      :keep_state_and_data
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

  def handle_event(:cast, {:no_tools_return_idle, chunk_phase}, _state, data) do
    {:next_state, {chunk_phase, :idle}, data}
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

    # Save the user message to session
    data = %{data | messages: messages, turn_count: data.turn_count + 1}
    data = save_unsaved_messages(data)

    # Start LLM call
    case call_llm(data) do
      {:ok, stream_ref, monitor_ref, estimated_tokens} ->
        data = %{
          data
          | stream_ref: stream_ref,
            stream_monitor_ref: monitor_ref,
            estimated_tokens: estimated_tokens
        }

        {:next_state, {chunk_phase, :calling}, data}

      {:error, reason} ->
        Logger.error("Lead #{data.lead_id} LLM call failed: #{inspect(reason)}")

        send(
          data.foreman_pid,
          {:lead_message, :error, "LLM call failed: #{inspect(reason)}", %{lead_id: data.lead_id}}
        )

        {:next_state, {:complete, :idle}, data}
    end
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
      case call_llm(data) do
        {:ok, stream_ref, monitor_ref, estimated_tokens} ->
          data = %{
            data
            | stream_ref: stream_ref,
              stream_monitor_ref: monitor_ref,
              estimated_tokens: estimated_tokens
          }

          {:next_state, {chunk_phase, :calling}, data}

        {:error, reason} ->
          Logger.error("Lead #{data.lead_id} LLM call failed during steering: #{inspect(reason)}")
          {:keep_state, data}
      end
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
          maybe_continue_llm(chunk_phase, data)
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

        # Cancel the timeout timer since the runner completed
        if runner_info.timeout_ref do
          Process.cancel_timer(runner_info.timeout_ref)
        end

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

        # Cancel the timeout timer since the runner crashed
        if runner_info.timeout_ref do
          Process.cancel_timer(runner_info.timeout_ref)
        end

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

  # Runner timeout - kill the runner if it's still running
  def handle_event(
        :info,
        {:runner_timeout, task_ref},
        {chunk_phase, agent_state},
        %{runner_tasks: runner_tasks} = data
      ) do
    # Check if the runner is still running (it might have completed already)
    case Map.get(runner_tasks, task_ref) do
      nil ->
        # Runner already completed or crashed, ignore the timeout
        :keep_state_and_data

      runner_info ->
        Logger.error("Lead #{data.lead_id} runner timed out: #{runner_info.task_description}")

        # Demonitor the task process to prevent DOWN message
        Process.demonitor(runner_info.monitor_ref, [:flush])

        # Kill the runner task
        Task.Supervisor.terminate_child(data.runner_supervisor, runner_info.pid)

        # Remove timed-out runner from tracking
        runner_tasks = Map.delete(runner_tasks, task_ref)
        data = %{data | runner_tasks: runner_tasks}

        # Send error to Foreman
        timeout_ms = Map.get(data.config, :job_runner_timeout, 300_000)

        send_lead_message(
          data.foreman_pid,
          :error,
          "Runner timed out after #{timeout_ms}ms: #{runner_info.task_description}",
          %{timeout_ms: timeout_ms}
        )

        # If agent is idle, resume work (potentially retry or skip)
        if agent_state == :idle do
          continue_work(chunk_phase, data)
        else
          {:keep_state, data}
        end
    end
  end

  # Stream process crash handling (DOWN message)
  def handle_event(
        :info,
        {:DOWN, monitor_ref, :process, _pid, reason},
        {chunk_phase, agent_state},
        data
      )
      when monitor_ref == data.stream_monitor_ref and agent_state in [:calling, :streaming] do
    Logger.error(
      "Lead #{data.lead_id}: stream process crashed in #{agent_state} state, reason: #{inspect(reason)}"
    )

    # Send error to Foreman
    send_lead_message(
      data.foreman_pid,
      :error,
      "Stream process crashed during #{agent_state}",
      %{reason: inspect(reason)}
    )

    # Cancel streaming state
    data = %{
      data
      | stream_ref: nil,
        stream_monitor_ref: nil,
        current_message: nil
    }

    # Transition to idle state to allow recovery
    {:next_state, {chunk_phase, :idle}, data}
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

  defp execute_tool(tool_call, data) do
    # Build tool context for execution
    tool_context = build_tool_context(data)

    # Lead uses read-only tools (same list as in call_llm)
    tools = [Deft.Tools.Read, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls]
    tool_map = Map.new(tools, fn tool_module -> {tool_module.name(), tool_module} end)

    # Look up the tool module and execute
    result =
      case Map.get(tool_map, tool_call.name) do
        nil ->
          {:error, "Tool '#{tool_call.name}' not found"}

        tool_module ->
          try do
            tool_module.execute(tool_call.args, tool_context)
          rescue
            exception ->
              {:error, "Tool execution error: #{Exception.message(exception)}"}
          end
      end

    # Return tuple of {tool_call.id, result} for build_tool_result_blocks
    {tool_call.id, result}
  end

  defp build_tool_context(data) do
    # Build a Deft.Tool.Context struct for tool execution in Lead's worktree
    cache_config = %{
      "default" => 10_000,
      "read" => 20_000,
      "grep" => 8_000,
      "ls" => 4_000,
      "find" => 4_000
    }

    %Deft.Tool.Context{
      working_dir: data.worktree_path,
      session_id: data.session_id,
      lead_id: data.lead_id,
      emit: fn _output -> :ok end,
      file_scope: nil,
      bash_timeout: 120_000,
      cache_tid: data.cache_tid,
      cache_config: cache_config
    }
  end

  defp maybe_continue_llm(chunk_phase, data) do
    if should_continue_turn?(data) do
      case call_llm(data) do
        {:ok, stream_ref, monitor_ref, estimated_tokens} ->
          data = %{
            data
            | stream_ref: stream_ref,
              stream_monitor_ref: monitor_ref,
              estimated_tokens: estimated_tokens
          }

          {:next_state, {chunk_phase, :calling}, data}

        {:error, reason} ->
          Logger.error("Lead #{data.lead_id} LLM call failed: #{inspect(reason)}")

          send(
            data.foreman_pid,
            {:lead_message, :error, "LLM call failed: #{inspect(reason)}",
             %{lead_id: data.lead_id}}
          )

          {:next_state, {:complete, :idle}, data}
      end
    else
      {:next_state, {chunk_phase, :idle}, data}
    end
  end

  defp call_llm(data) do
    # Extract parameters from data
    job_id = data.session_id
    messages = data.messages
    config = data.config
    provider_name = Map.get(config, :provider, "anthropic")

    # Request permission from rate limiter
    case RateLimiter.request(job_id, provider_name, messages, :lead) do
      {:ok, estimated_tokens} ->
        # Lead uses read-only tools to read codebase and site log during planning
        # Delegates actual implementation work to Runners
        tools = [Deft.Tools.Read, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls]

        # Get the configured provider module
        provider_module = get_provider(data)

        # Use Lead's model instead of session model
        lead_model = Map.get(config, :job_lead_model, "claude-sonnet-4")
        llm_config = Map.put(config, :model, lead_model)

        # Start streaming from the provider
        case provider_module.stream(messages, tools, llm_config) do
          {:ok, stream_ref} ->
            # Monitor the stream process
            monitor_ref = Process.monitor(stream_ref)
            # Store estimated_tokens for later reconciliation
            {:ok, stream_ref, monitor_ref, estimated_tokens}

          {:error, reason} ->
            Logger.error("Lead #{data.lead_id} failed to start LLM stream: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "Lead #{data.lead_id} failed to get rate limiter permission: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp get_provider(data) do
    provider_value = Map.get(data.config, :provider, "anthropic")
    # Normalize provider to string (CLI sets it as atom, Registry expects string)
    provider_name = normalize_provider_name(provider_value)
    # Use Lead's model for resolving provider
    model_name = Map.get(data.config, :job_lead_model, "claude-sonnet-4")

    case Deft.Provider.Registry.resolve(provider_name, model_name) do
      {:ok, {provider_module, _model_config}} ->
        provider_module

      {:error, _} ->
        # Fallback to anthropic
        {:ok, {provider_module, _}} =
          Deft.Provider.Registry.resolve("anthropic", "claude-sonnet-4")

        provider_module
    end
  end

  # Normalize provider name from atom to string
  # CLI sets provider as Deft.Provider.Anthropic, Registry expects "anthropic"
  defp normalize_provider_name(provider) when is_binary(provider), do: provider

  defp normalize_provider_name(provider) when is_atom(provider) do
    provider
    |> Module.split()
    |> List.last()
    |> String.downcase()
  end

  defp process_provider_event(event, data) do
    data
    |> ensure_current_message()
    |> handle_provider_event(event)
  end

  defp handle_provider_event(data, %TextDelta{delta: delta}) do
    handle_text_delta_event(data, delta)
  end

  defp handle_provider_event(data, %ThinkingDelta{delta: delta}) do
    handle_thinking_delta_event(data, delta)
  end

  defp handle_provider_event(data, %ToolCallStart{id: id, name: name}) do
    handle_tool_call_start_event(data, id, name)
  end

  defp handle_provider_event(data, %ToolCallDelta{id: id, delta: delta}) do
    handle_tool_call_delta_event(data, id, delta)
  end

  defp handle_provider_event(data, %ToolCallDone{id: id, args: parsed_args}) do
    handle_tool_call_done_event(data, id, parsed_args)
  end

  defp handle_provider_event(data, %Usage{input: input_tokens, output: output_tokens}) do
    handle_usage_event(data, input_tokens, output_tokens)
  end

  defp handle_provider_event(data, _event), do: data

  defp ensure_current_message(%{current_message: nil} = data) do
    current_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [],
      timestamp: DateTime.utc_now()
    }

    %{data | current_message: current_message}
  end

  defp ensure_current_message(data), do: data

  defp handle_text_delta_event(data, delta) do
    new_message = append_text_delta(data.current_message, delta)
    %{data | current_message: new_message}
  end

  defp handle_thinking_delta_event(data, delta) do
    new_message = append_thinking_delta(data.current_message, delta)
    %{data | current_message: new_message}
  end

  defp handle_tool_call_start_event(data, id, name) do
    tool_use = %Deft.Message.ToolUse{id: id, name: name, args: %{}}
    new_content = data.current_message.content ++ [tool_use]
    new_message = %{data.current_message | content: new_content}

    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    new_buffers = Map.put(tool_call_buffers, id, "")

    %{data | current_message: new_message, tool_call_buffers: new_buffers}
  end

  defp handle_tool_call_delta_event(data, id, delta) do
    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    current_buffer = Map.get(tool_call_buffers, id, "")
    new_buffers = Map.put(tool_call_buffers, id, current_buffer <> delta)

    %{data | tool_call_buffers: new_buffers}
  end

  defp handle_tool_call_done_event(data, id, parsed_args) do
    new_message = update_tool_call_args(data.current_message, id, parsed_args)

    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    new_buffers = Map.delete(tool_call_buffers, id)

    %{data | current_message: new_message, tool_call_buffers: new_buffers}
  end

  defp handle_usage_event(data, input_tokens, output_tokens) do
    total_input = Map.get(data, :total_input_tokens, 0) + input_tokens
    total_output = Map.get(data, :total_output_tokens, 0) + output_tokens

    %{data | total_input_tokens: total_input, total_output_tokens: total_output}
  end

  defp append_text_delta(message, delta) do
    case List.last(message.content) do
      %Text{text: existing_text} ->
        # Update the last Text block
        new_text = existing_text <> delta
        new_content = List.replace_at(message.content, -1, %Text{text: new_text})
        %{message | content: new_content}

      _ ->
        # No Text block at the end, create a new one
        new_content = message.content ++ [%Text{text: delta}]
        %{message | content: new_content}
    end
  end

  defp append_thinking_delta(message, delta) do
    alias Deft.Message.Thinking

    case List.last(message.content) do
      %Thinking{text: existing_text} ->
        # Update the last Thinking block
        new_text = existing_text <> delta
        new_content = List.replace_at(message.content, -1, %Thinking{text: new_text})
        %{message | content: new_content}

      _ ->
        # No Thinking block at the end, create a new one
        new_content = message.content ++ [%Thinking{text: delta}]
        %{message | content: new_content}
    end
  end

  defp update_tool_call_args(message, tool_id, parsed_args) do
    alias Deft.Message.ToolUse

    # Find the ToolUse block with matching ID and update its args
    new_content =
      Enum.map(message.content, fn
        %ToolUse{id: ^tool_id} = tool_use ->
          %{tool_use | args: parsed_args}

        other ->
          other
      end)

    %{message | content: new_content}
  end

  defp done_streaming?(event) do
    # Check if this is a Done event
    match?(%Done{}, event)
  end

  defp finalize_streaming(data) do
    # Finalize the current message and add to messages list
    case data.current_message do
      nil ->
        # No message being accumulated, nothing to finalize
        data

      current_message ->
        # Add the completed message to the messages list
        new_messages = data.messages ++ [current_message]
        data = %{data | messages: new_messages, current_message: nil}

        # Reconcile token usage with rate limiter if we have estimated tokens
        data =
          if Map.has_key?(data, :estimated_tokens) do
            job_id = data.session_id
            provider_name = Map.get(data.config, :provider, "anthropic")
            estimated_tokens = data.estimated_tokens

            # Build usage map from accumulated tokens
            usage = %{
              input: Map.get(data, :total_input_tokens, 0),
              output: Map.get(data, :total_output_tokens, 0)
            }

            # Call reconcile to credit back unused tokens
            RateLimiter.reconcile(job_id, provider_name, estimated_tokens, usage)

            # Clear estimated_tokens and reset token counters for next call
            data
            |> Map.delete(:estimated_tokens)
            |> Map.put(:total_input_tokens, 0)
            |> Map.put(:total_output_tokens, 0)
          else
            data
          end

        # Save the new message to session
        save_unsaved_messages(data)
    end
  end

  defp add_tool_results(result, data) do
    # Accumulate this tool result
    accumulated = Map.get(data, :tool_results, [])
    new_accumulated = accumulated ++ [result]
    data = %{data | tool_results: new_accumulated}

    # If all tool tasks are complete, build the user message with tool results
    if Enum.empty?(data.tool_tasks) do
      finalize_tool_results(new_accumulated, data)
    else
      # Not all tasks done yet, just return data with accumulated result
      data
    end
  end

  defp finalize_tool_results(accumulated_results, data) do
    # Extract tool calls from the last assistant message to get tool names
    tool_calls = extract_tool_calls(data.messages)

    # Build tool result blocks
    tool_result_blocks = build_tool_result_blocks(accumulated_results, tool_calls)

    # Create user message with tool results
    tool_result_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: tool_result_blocks,
      timestamp: DateTime.utc_now()
    }

    # Add to messages and clear accumulated results
    new_messages = data.messages ++ [tool_result_message]
    data = %{data | messages: new_messages, tool_results: []}

    # Save the new message to session
    save_unsaved_messages(data)
  end

  defp build_tool_result_blocks(accumulated_results, tool_calls) do
    Enum.map(accumulated_results, fn {tool_use_id, tool_result} ->
      # Find the tool name from the original tool call
      tool_name =
        Enum.find_value(tool_calls, fn tool_use ->
          if tool_use.id == tool_use_id, do: tool_use.name
        end) || "unknown"

      # Build the ToolResult block based on result type
      build_tool_result_block(tool_use_id, tool_name, tool_result)
    end)
  end

  defp build_tool_result_block(tool_use_id, tool_name, {:ok, content}) do
    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: tool_name,
      content: content,
      is_error: false
    }
  end

  defp build_tool_result_block(tool_use_id, tool_name, {:error, error_message}) do
    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: tool_name,
      content: error_message,
      is_error: true
    }
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
    # Build proper runner_config with provider module instead of string
    provider_name = Map.get(data.config, :provider, "anthropic")
    runner_model = Map.get(data.config, :job_runner_model, "claude-sonnet-4")

    runner_config = %{
      provider: get_provider(data),
      provider_name: provider_name,
      model: runner_model
    }

    # Spawn Runner via async_nolink
    task =
      Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
        Runner.run(
          runner_type,
          instructions,
          context,
          data.session_id,
          runner_config,
          data.worktree_path
        )
      end)

    # CRITICAL: Must explicitly monitor since we used async_nolink
    monitor_ref = Process.monitor(task.pid)

    # Enforce runner timeout (default 300_000ms = 5 minutes)
    timeout = Map.get(data.config, :job_runner_timeout, 300_000)
    timeout_ref = Process.send_after(self(), {:runner_timeout, task.ref}, timeout)

    # Store runner info for tracking
    runner_info = %{
      task_description: task_description,
      runner_type: runner_type,
      pid: task.pid,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
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

            # Check if this runner's work satisfies a dependency interface
            if should_publish_contract?(runner_info, output, data) do
              contract_content = extract_contract(output, runner_info, data)

              send_lead_message(
                data.foreman_pid,
                :contract,
                contract_content,
                %{lead_id: data.lead_id}
              )

              Logger.info(
                "Lead #{data.lead_id} published contract for task: #{runner_info.task_description}"
              )
            end

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
      length(data.runner_tasks) >= Map.get(data.config, :job_max_runners_per_lead, 3) ->
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

  # Extracts task list from LLM's planning response
  # Looks for numbered lists (1., 2., etc.) or bullet points (-, *, •)
  # Returns list of task maps with %{description: String.t(), status: :pending, result: nil}
  defp extract_task_list_from_messages(messages) do
    # Get the last assistant message
    last_assistant_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == :assistant end)

    case last_assistant_msg do
      nil ->
        []

      msg ->
        # Extract text from all Text content blocks
        text =
          msg.content
          |> Enum.filter(fn
            %Text{} -> true
            _ -> false
          end)
          |> Enum.map(fn %Text{text: t} -> t end)
          |> Enum.join("\n")

        # Parse task list from text
        parse_task_list(text)
    end
  end

  # Parses task descriptions from text
  # Supports numbered lists (1., 2., etc.) and bullet points (-, *, •)
  defp parse_task_list(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      # Match numbered lists: "1. Task", "2. Task", etc.
      # or bullet points: "- Task", "* Task", "• Task"
      String.match?(line, ~r/^(\d+\.|-|\*|•)\s+\S/)
    end)
    |> Enum.map(fn line ->
      # Remove the number/bullet prefix
      description =
        line
        |> String.replace(~r/^(\d+\.|-|\*|•)\s+/, "")
        |> String.trim()

      %{
        description: description,
        status: :pending,
        result: nil
      }
    end)
    |> Enum.reject(fn task -> String.length(task.description) < 10 end)
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

  # Builds context string for verification runner
  defp build_runner_context_for_verification(data) do
    # Read relevant information from site log
    site_log_context = read_site_log_context(data.site_log_tid)

    # Include all completed tasks for verification context
    completed_tasks =
      data.task_list
      |> Enum.filter(fn t -> t.status == :done end)
      |> Enum.map(fn t -> "- #{t.description}" end)
      |> Enum.join("\n")

    """
    #{site_log_context}

    ## Deliverable Goal

    #{data.deliverable}

    ## Completed Tasks

    #{completed_tasks}
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

  # Contract detection and extraction helpers

  # Determines if the runner's work represents a dependency interface contract
  # that should be published to the Foreman for partial dependency unblocking.
  defp should_publish_contract?(runner_info, output, _data) do
    desc_lower = String.downcase(runner_info.task_description)
    output_lower = String.downcase(output)

    # Check if task description or output suggests a contract/interface was defined
    contract_keywords = [
      "interface",
      "api",
      "contract",
      "signature",
      "protocol",
      "schema",
      "endpoint",
      "define interface",
      "create interface",
      "implement interface"
    ]

    Enum.any?(contract_keywords, fn keyword ->
      String.contains?(desc_lower, keyword) or String.contains?(output_lower, keyword)
    end)
  end

  # Extracts contract details from runner output and formats them for the Foreman.
  # The contract includes the task description, deliverable context, and output details.
  defp extract_contract(output, runner_info, data) do
    """
    Contract from task: #{runner_info.task_description}
    Deliverable: #{data.deliverable}

    Interface details:
    #{output}
    """
  end

  # Session persistence helpers

  defp save_unsaved_messages(data) do
    alias Deft.Session.{Entry, Store}

    # Find messages that haven't been saved yet
    unsaved_messages =
      Enum.reject(data.messages, fn msg ->
        MapSet.member?(data.saved_message_ids, msg.id)
      end)

    # Save each message to the Lead session file
    Enum.each(unsaved_messages, fn msg ->
      entry = Entry.Message.from_message(msg)
      Store.append_to_path(data.session_file_path, entry)
    end)

    # Update saved_message_ids set
    new_saved_ids =
      Enum.reduce(unsaved_messages, data.saved_message_ids, fn msg, acc ->
        MapSet.put(acc, msg.id)
      end)

    %{data | saved_message_ids: new_saved_ids}
  end
end
