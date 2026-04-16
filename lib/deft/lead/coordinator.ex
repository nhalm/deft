defmodule Deft.Lead.Coordinator do
  @moduledoc """
  Lead orchestrator — manages a single deliverable using a gen_statem with 4 pure orchestration states.

  The v0.7 redesign splits the Lead into two processes:
  - Lead Coordinator (this module): Pure orchestration gen_statem managing deliverable lifecycle
  - Lead: Standard Deft.Agent that does LLM reasoning

  ## Lead Phase States

  - `:planning` — Sends deliverable assignment to Lead, which decomposes into tasks
  - `:executing` — Spawns Runners on request, collects results, sends to Lead
  - `:verifying` — Spawns testing Runner
  - `:complete` — Sends `:complete` to Foreman

  ## Communication

  **Lead → Lead Coordinator:** Via `Deft.Agent.prompt/2`
  **Lead → Lead Coordinator:** Via orchestration tools that send `{:agent_action, action, payload}` messages
  **Foreman → Lead Coordinator:** Via `{:foreman_steering, content}` messages
  **Lead Coordinator → Foreman:** Via `{:lead_message, type, content, metadata}` messages

  ## Runner Management

  Runners are spawned via `Task.Supervisor.async_nolink`. The Lead Coordinator monitors each Runner
  task via Task refs for completion.
  """

  @behaviour :gen_statem

  alias Deft.Job.Runner
  alias Deft.Store

  require Logger

  # Client API

  @doc """
  Starts the Lead Coordinator gen_statem.

  ## Options

  - `:lead_id` — Required. Unique identifier for this Lead.
  - `:session_id` — Required. Job session identifier.
  - `:config` — Required. Configuration map.
  - `:deliverable` — Required. Deliverable assignment (map with name, description, etc.).
  - `:foreman_pid` — Required. PID of the Foreman for messaging.
  - `:site_log_name` — Required. Registered name of Deft.Store site log instance.
  - `:rate_limiter_pid` — Required. PID of Deft.RateLimiter.
  - `:worktree_path` — Required. Path to Lead's git worktree.
  - `:working_dir` — Required. Project working directory for cache path resolution.
  - `:runner_supervisor` — Required. Name/PID of the Lead's Task.Supervisor for Runners.
  - `:lead_agent_pid` — Optional. Via-tuple or PID of the Lead (will be set by supervisor).
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
    lead_agent_pid = Keyword.get(opts, :lead_agent_pid)
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
      working_dir: working_dir,
      runner_supervisor: runner_supervisor,
      lead_agent_pid: lead_agent_pid,
      runner_tasks: %{},
      runner_results: [],
      task_list: [],
      queued_steering: [],
      lead_start_time: System.monotonic_time(:millisecond)
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Sets the Lead agent after the agent is started by the supervisor.

  Accepts either a via-tuple (production) or raw PID (tests).
  """
  def set_lead_agent(lead, agent_name_or_pid) do
    :gen_statem.cast(lead, {:set_lead_agent, agent_name_or_pid})
  end

  @doc """
  Sends Foreman steering to the Lead Coordinator.
  """
  def steer(lead, content) do
    GenServer.cast(lead, {:foreman_steering, content})
  end

  @doc """
  Spawns a Runner task and returns updated tracking data.

  This is a public API for testing purposes. In production, Runners are spawned
  via agent action messages.

  Returns `{:ok, task_ref, monitor_ref, updated_data}` on success.
  """
  def spawn_runner(data, runner_type, task_description, instructions, context) do
    # Build Runner options
    opts = %{
      job_id: data.session_id,
      config: data.config,
      worktree_path: data.worktree_path,
      rate_limiter_pid: data.rate_limiter_pid
    }

    # Spawn Runner task
    task =
      Task.Supervisor.async_nolink(
        data.runner_supervisor,
        fn -> Runner.run(runner_type, instructions, context, opts) end
      )

    # Get timeout from config
    timeout = Map.get(data.config, :job_runner_timeout, 300_000)

    # Set up timeout enforcement
    timeout_ref = Process.send_after(self(), {:runner_timeout, task.ref}, timeout)

    # Track the runner with all metadata
    runner_info = %{
      task_description: task_description,
      runner_type: runner_type,
      pid: task.pid,
      monitor_ref: task.ref,
      timeout_ref: timeout_ref,
      started_at: System.monotonic_time(:millisecond)
    }

    # Update runner tracking
    runner_tasks = Map.put(data.runner_tasks, task.ref, runner_info)
    updated_data = Map.put(data, :runner_tasks, runner_tasks)

    {:ok, task.ref, task.ref, updated_data}
  end

  @doc """
  Sends a message to the Foreman.

  This is a public API for testing purposes. In production, messages are sent
  via the private send_to_foreman/4 helper.
  """
  def send_lead_message(foreman_pid, type, content, metadata) do
    GenServer.cast(foreman_pid, {:lead_message, type, content, metadata})
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(data) do
    Logger.info(
      "[Lead:#{data.lead_id}] Started for deliverable: #{inspect(data.deliverable[:name])}"
    )

    {:ok, :planning, data}
  end

  # State enter callbacks

  @impl :gen_statem
  def handle_event(:enter, _old_state, :planning, data) do
    Logger.info("[Lead:#{data.lead_id}] Entering :planning phase")

    # Send deliverable assignment + site log context to Lead
    if data.lead_agent_pid do
      # Read research findings and contracts from site log
      site_log_context = read_site_log_context(data)
      context = build_planning_context(data, site_log_context)
      Deft.Agent.prompt(data.lead_agent_pid, context)
    end

    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :executing, data) do
    Logger.info("[Lead:#{data.lead_id}] Entering :executing phase")
    # Runners will be spawned based on Lead requests
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :verifying, data) do
    Logger.info("[Lead:#{data.lead_id}] Entering :verifying phase")
    # Spawn testing Runner
    data = spawn_testing_runner(data)
    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, :complete, data) do
    Logger.info("[Lead:#{data.lead_id}] Entering :complete phase")

    # Check if there's queued steering to apply BEFORE sending completion to Foreman
    case data.queued_steering do
      [] ->
        complete_without_steering(data)

      queued_items when is_list(queued_items) and length(queued_items) > 0 ->
        complete_with_queued_steering(data, queued_items)
    end
  end

  # Handle state_timeout to apply queued steering and transition to :executing
  def handle_event(:state_timeout, :apply_queued_steering, :complete, data) do
    Logger.debug(
      "[Lead:#{data.lead_id}] Transitioning from :complete to :executing due to queued steering"
    )

    {:next_state, :executing, data}
  end

  # Set Lead agent (via-tuple or PID)
  def handle_event(:cast, {:set_lead_agent, agent_name_or_pid}, _state, data) do
    Logger.debug("[Lead:#{data.lead_id}] Lead agent set: #{inspect(agent_name_or_pid)}")
    data = Map.put(data, :lead_agent_pid, agent_name_or_pid)
    {:keep_state, data}
  end

  # Handle agent actions from Lead orchestration tools

  def handle_event(:info, {:agent_action, :spawn_runner, type, instructions}, state, data)
      when state in [:planning, :executing] do
    Logger.info("[Lead:#{data.lead_id}] Lead requested spawning #{type} Runner")

    # Build Runner context and options
    context = build_runner_context(data)

    opts = %{
      job_id: data.session_id,
      config: data.config,
      worktree_path: data.worktree_path,
      rate_limiter_pid: data.rate_limiter_pid
    }

    # Spawn Runner task
    task =
      Task.Supervisor.async_nolink(
        data.runner_supervisor,
        fn -> Runner.run(type, instructions, context, opts) end
      )

    # Get timeout from config
    timeout = Map.get(data.config, :job_runner_timeout, 300_000)

    # Set up timeout enforcement
    timeout_ref = Process.send_after(self(), {:runner_timeout, task.ref}, timeout)

    # Track the task with timeout enforcement
    runner_info = %{
      task: task,
      task_description: "#{type} runner",
      runner_type: type,
      pid: task.pid,
      monitor_ref: task.ref,
      timeout_ref: timeout_ref,
      started_at: System.monotonic_time(:millisecond)
    }

    runner_tasks = Map.put(data.runner_tasks, task.ref, runner_info)
    data = Map.put(data, :runner_tasks, runner_tasks)

    # Transition to :executing if in :planning
    if state == :planning do
      {:next_state, :executing, data}
    else
      {:keep_state, data}
    end
  end

  def handle_event(:info, {:agent_action, :publish_contract, content}, state, data)
      when state in [:planning, :executing] do
    Logger.info("[Lead:#{data.lead_id}] Lead publishing contract")

    send_to_foreman(data, :contract, content, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :report, report_type, content}, state, data)
      when state in [:planning, :executing] do
    Logger.info("[Lead:#{data.lead_id}] Lead reporting: #{report_type}")

    send_to_foreman(data, report_type, content, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :blocker, description}, state, data)
      when state in [:planning, :executing] do
    Logger.warning("[Lead:#{data.lead_id}] Lead blocked: #{description}")

    send_to_foreman(data, :blocker, description, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  # Handle Runner timeout
  def handle_event(:info, {:runner_timeout, task_ref}, _state, data) do
    case Map.get(data.runner_tasks, task_ref) do
      nil ->
        # Runner already completed or cleaned up
        :keep_state_and_data

      runner_info ->
        Logger.warning(
          "[Lead:#{data.lead_id}] Runner #{runner_info.runner_type} timed out (task: #{runner_info.task_description})"
        )

        # Kill the timed-out Runner process
        if Process.alive?(runner_info.pid) do
          Process.exit(runner_info.pid, :kill)
        end

        # Remove from tracking
        remaining_tasks = Map.delete(data.runner_tasks, task_ref)
        data = Map.put(data, :runner_tasks, remaining_tasks)

        # Report timeout to Foreman
        send_to_foreman(data, :error, "Runner #{runner_info.runner_type} timed out", %{
          lead_id: data.lead_id,
          runner_type: runner_info.runner_type,
          task_description: runner_info.task_description
        })

        # Notify Lead so it can adjust approach
        if data.lead_agent_pid do
          timeout_prompt = """
          **RUNNER TIMEOUT**

          Runner type: #{runner_info.runner_type}
          Task: #{runner_info.task_description}
          Status: Timed out

          The Runner exceeded the configured timeout and was terminated. This usually means the task was too complex or got stuck.

          **Recovery Actions:**
          1. Break the task into smaller, more focused steps
          2. Simplify the instructions to reduce complexity
          3. Consider if the approach needs to change
          4. If repeatedly timing out, use `request_help` to escalate to the Foreman

          Please spawn a new Runner with an adjusted approach.
          """

          Deft.Agent.prompt(data.lead_agent_pid, timeout_prompt)
        end

        {:keep_state, data}
    end
  end

  # Handle Runner task completion
  def handle_event(:info, {ref, result}, state, data) when is_reference(ref) do
    case Map.pop(data.runner_tasks, ref) do
      {nil, _tasks} ->
        # Not our task
        :keep_state_and_data

      {runner_info, remaining_tasks} ->
        Logger.info("[Lead:#{data.lead_id}] Runner #{runner_info.runner_type} completed")

        # Cancel the timeout since the Runner completed
        _ =
          if runner_info[:timeout_ref] do
            Process.cancel_timer(runner_info.timeout_ref)
          end

        # Store result
        runner_results = [
          %{type: runner_info.runner_type, result: result} | data.runner_results
        ]

        data =
          data
          |> Map.put(:runner_tasks, remaining_tasks)
          |> Map.put(:runner_results, runner_results)

        # Send results to Lead
        if data.lead_agent_pid do
          context = build_runner_result_context(data, runner_info.runner_type, result)
          Deft.Agent.prompt(data.lead_agent_pid, context)
        end

        # Check if we should transition states after this runner completes
        handle_runner_completion_transition(state, remaining_tasks, result, data)
    end
  end

  # Handle Runner task DOWN (process exit)
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    case Map.pop(data.runner_tasks, ref) do
      {nil, _tasks} ->
        :keep_state_and_data

      {runner_info, remaining_tasks} ->
        Logger.error(
          "[Lead:#{data.lead_id}] Runner #{runner_info.runner_type} failed: #{inspect(reason)}"
        )

        # Cancel the timeout since the Runner is done (even if it crashed)
        _ =
          if runner_info[:timeout_ref] do
            Process.cancel_timer(runner_info.timeout_ref)
          end

        data = Map.put(data, :runner_tasks, remaining_tasks)

        # Report error to Foreman
        send_to_foreman(
          data,
          :error,
          "Runner #{runner_info.runner_type} failed: #{inspect(reason)}",
          %{
            lead_id: data.lead_id,
            runner_type: runner_info.runner_type
          }
        )

        # Send failure to Lead for recovery
        if data.lead_agent_pid do
          failure_prompt = """
          **RUNNER FAILURE**

          Runner type: #{runner_info.runner_type}
          Task: #{runner_info.task_description || "No description"}
          Status: Failed
          Reason: #{inspect(reason)}

          The Runner process crashed or exited unexpectedly. This may indicate:
          - An error in the Runner's execution
          - An unexpected condition that wasn't handled
          - A system-level issue

          **Recovery Actions:**
          1. Review the failure reason above
          2. Adjust your instructions to handle edge cases
          3. Consider if a different approach is needed
          4. If unclear how to proceed, use `request_help` to escalate to the Foreman

          Please analyze the failure and spawn a new Runner with corrective instructions.
          """

          Deft.Agent.prompt(data.lead_agent_pid, failure_prompt)
        end

        {:keep_state, data}
    end
  end

  # Handle Foreman steering
  def handle_event(:cast, {:foreman_steering, content}, state, data)
      when state in [:planning, :executing] do
    Logger.info("[Lead:#{data.lead_id}] Received steering from Foreman")

    # Inject steering into Lead as a prompt with current context
    if data.lead_agent_pid do
      # Build current progress context
      completed_count = length(data.runner_results)
      running_count = map_size(data.runner_tasks)

      steering_prompt = """
      **FOREMAN STEERING**

      The Foreman has sent you guidance:

      #{content}

      **Current Progress:**
      - Deliverable: #{data.deliverable[:name]}
      - Phase: #{state}
      - Runners completed: #{completed_count}
      - Runners running: #{running_count}

      **Action Required:**
      Review the Foreman's guidance and adjust your approach accordingly. Update your task plan if needed and continue with implementation.
      """

      Deft.Agent.prompt(data.lead_agent_pid, steering_prompt)
    end

    :keep_state_and_data
  end

  # Handle Foreman steering in :verifying state - queue it instead of processing
  def handle_event(:cast, {:foreman_steering, content}, :verifying, data) do
    Logger.info(
      "[Lead:#{data.lead_id}] Received steering from Foreman during :verifying, queuing"
    )

    # Queue the steering to be applied after verification completes
    queued_steering = [content | data.queued_steering]
    data = Map.put(data, :queued_steering, queued_steering)

    {:keep_state, data}
  end

  # Handle Foreman contract (partial dependency unblocking)
  def handle_event(:cast, {:foreman_contract, contract}, state, data)
      when state in [:planning, :executing] do
    Logger.info("[Lead:#{data.lead_id}] Received dependency contract from Foreman")

    # Forward contract to Lead as a prompt with context
    if data.lead_agent_pid do
      contract_prompt = """
      **DEPENDENCY CONTRACT AVAILABLE**

      A dependency you were waiting for has been satisfied. The interface contract is now available:

      #{inspect(contract, pretty: true)}

      **Action Required:**
      Review this contract and proceed with work that depends on this interface. You can now unblock any tasks that were waiting for this dependency.

      If you have questions about the contract or need clarification, use the `request_help` tool to ask the Foreman.
      """

      Deft.Agent.prompt(data.lead_agent_pid, contract_prompt)
    end

    :keep_state_and_data
  end

  # Fallback for unexpected events
  def handle_event(event_type, event_content, state, data) do
    Logger.warning(
      "[Lead:#{data.lead_id}] Unhandled event in state #{state}: #{event_type} #{inspect(event_content)}"
    )

    :keep_state_and_data
  end

  # Private helpers

  defp complete_without_steering(data) do
    # No queued steering, send completion to Foreman
    send_to_foreman(data, :complete, "Deliverable completed", %{
      lead_id: data.lead_id,
      deliverable: data.deliverable
    })

    :keep_state_and_data
  end

  defp complete_with_queued_steering(data, queued_items) do
    # Apply ALL queued steering by concatenating into a single prompt
    Logger.info(
      "[Lead:#{data.lead_id}] Applying #{length(queued_items)} queued steering item(s) after verification, re-entering :executing"
    )

    apply_queued_steering_to_agent(data, queued_items)

    # Clear queued steering and schedule transition to :executing without notifying Foreman
    # Use state_timeout with 0 to trigger the transition immediately after the enter callback completes
    data = Map.put(data, :queued_steering, [])
    {:keep_state, data, [{:state_timeout, 0, :apply_queued_steering}]}
  end

  defp apply_queued_steering_to_agent(data, queued_items) do
    if data.lead_agent_pid do
      combined_steering = combine_steering_items(queued_items)
      steering_prompt = build_queued_steering_prompt(data, combined_steering)
      Deft.Agent.prompt(data.lead_agent_pid, steering_prompt)
    end
  end

  defp combine_steering_items(queued_items) do
    queued_items
    |> Enum.with_index(1)
    |> Enum.map(fn {content, index} ->
      format_steering_item(content, index, length(queued_items))
    end)
    |> Enum.join("\n\n")
  end

  defp format_steering_item(content, index, total_items) when total_items > 1 do
    "**Steering Item #{index}:**\n#{content}"
  end

  defp format_steering_item(content, _index, _total_items), do: content

  defp build_queued_steering_prompt(data, combined_steering) do
    """
    **FOREMAN STEERING (Queued During Verification)**

    The Foreman sent guidance while verification was in progress:

    #{combined_steering}

    **Current Status:**
    - Deliverable: #{data.deliverable[:name]}
    - Verification has completed
    - The Foreman's steering may indicate changes needed despite passing tests

    **Action Required:**
    Review the Foreman's guidance and determine if changes are needed. If the steering contradicts the verification result or requests modifications, implement them now.
    """
  end

  defp build_planning_context(data, site_log_context) do
    """
    You are the Lead managing the following deliverable:

    **Deliverable:** #{data.deliverable[:name]}
    **Description:** #{data.deliverable[:description] || "No description provided"}

    #{format_site_log_context(site_log_context)}

    **Your responsibilities:**
    1. Analyze the deliverable assignment, research findings, and available contracts
    2. Decompose the deliverable into concrete implementation tasks
    3. Use your available tools to spawn Runners, publish contracts, and report progress
    4. Evaluate Runner output and request corrective Runners if needed
    5. Request testing Runners to verify compile checks and tests after implementation

    **Available tools:**
    - `spawn_runner` — Start a Runner to execute a task (types: :implementation, :testing, :review)
    - `publish_contract` — Publish an interface contract for dependent Leads
    - `report_status` — Send progress updates to the Foreman
    - `request_help` — Escalate blockers to the Foreman

    **Worktree path:** #{data.worktree_path}

    Begin by analyzing the deliverable, reviewing available research findings and contracts, then planning your approach. When ready, spawn your first Runner.
    """
  end

  defp read_site_log_context(data) do
    case get_site_log_tid(data) do
      nil ->
        %{research: [], contracts: [], decisions: [], critical: []}

      tid ->
        tid
        |> Store.keys()
        |> categorize_site_log_entries(tid)
    end
  end

  defp get_site_log_tid(data) do
    try do
      Store.tid(data.site_log_name)
    rescue
      _ ->
        Logger.warning("[Lead:#{data.lead_id}] Could not access site log")
        nil
    end
  end

  defp categorize_site_log_entries(keys, tid) do
    Enum.reduce(keys, %{research: [], contracts: [], decisions: [], critical: []}, fn key, acc ->
      categorize_entry(tid, key, acc)
    end)
  end

  defp categorize_entry(tid, key, acc) do
    case Store.read(tid, key) do
      {:ok, entry} ->
        add_entry_to_category(entry, key, acc)

      _ ->
        acc
    end
  end

  defp add_entry_to_category(entry, key, acc) do
    case entry[:metadata][:type] do
      :finding -> Map.update!(acc, :research, &[{key, entry} | &1])
      :contract -> Map.update!(acc, :contracts, &[{key, entry} | &1])
      :decision -> Map.update!(acc, :decisions, &[{key, entry} | &1])
      :critical_finding -> Map.update!(acc, :critical, &[{key, entry} | &1])
      _ -> acc
    end
  end

  defp format_site_log_context(context) do
    sections =
      []
      |> maybe_add_research_findings(context[:research])
      |> maybe_add_contracts(context[:contracts])
      |> maybe_add_critical_findings(context[:critical])
      |> maybe_add_decisions(context[:decisions])

    if sections == [] do
      ""
    else
      "\n" <> Enum.join(Enum.reverse(sections), "\n")
    end
  end

  defp maybe_add_research_findings(sections, findings) when findings != [] do
    findings_text =
      findings
      |> Enum.map(fn {key, entry} ->
        "- #{key}: #{inspect(entry[:value])}"
      end)
      |> Enum.join("\n")

    [
      """
      **Research Findings:**
      #{findings_text}
      """
      | sections
    ]
  end

  defp maybe_add_research_findings(sections, _), do: sections

  defp maybe_add_contracts(sections, contracts) when contracts != [] do
    contracts_text =
      contracts
      |> Enum.map(fn {key, entry} ->
        "- #{key}: #{inspect(entry[:value])}"
      end)
      |> Enum.join("\n")

    [
      """
      **Available Contracts:**
      #{contracts_text}
      """
      | sections
    ]
  end

  defp maybe_add_contracts(sections, _), do: sections

  defp maybe_add_critical_findings(sections, findings) when findings != [] do
    critical_text =
      findings
      |> Enum.map(fn {key, entry} ->
        "- #{key}: #{inspect(entry[:value])}"
      end)
      |> Enum.join("\n")

    [
      """
      **Critical Findings:**
      #{critical_text}
      """
      | sections
    ]
  end

  defp maybe_add_critical_findings(sections, _), do: sections

  defp maybe_add_decisions(sections, decisions) when decisions != [] do
    decisions_text =
      decisions
      |> Enum.map(fn {key, entry} ->
        "- #{key}: #{inspect(entry[:value])}"
      end)
      |> Enum.join("\n")

    [
      """
      **Foreman Decisions:**
      #{decisions_text}
      """
      | sections
    ]
  end

  defp maybe_add_decisions(sections, _), do: sections

  defp build_runner_result_context(data, runner_type, result) do
    # Count completed and running runners
    completed_count = length(data.runner_results)
    running_count = map_size(data.runner_tasks)

    """
    **Runner Completion Report**

    Runner type: #{runner_type}
    Status: Completed

    **Result:**
    #{inspect(result, pretty: true)}

    **Progress Summary:**
    - Runners completed: #{completed_count}
    - Runners currently running: #{running_count}
    - Deliverable: #{data.deliverable[:name]}

    **Next Steps:**
    Evaluate this output and decide on the next action:
    - If successful and this was an implementation Runner, spawn a testing Runner to verify compile checks and tests
    - If there are issues, spawn a corrective Runner with specific guidance
    - If the deliverable is complete and verified, you can wait for the Lead Coordinator to transition to verification phase
    - If you need to publish an interface contract, use the `publish_contract` tool
    - Report progress to the Foreman using `report_status` with important decisions or artifacts
    """
  end

  # Handle state transitions after a runner completes
  defp handle_runner_completion_transition(:verifying, remaining_tasks, result, data)
       when map_size(remaining_tasks) == 0 do
    # In verifying state with no more tasks - inspect test result to decide next state
    case result do
      {:ok, _output} ->
        # Tests passed, transition to complete
        Logger.info("[Lead:#{data.lead_id}] Testing passed, transitioning to :complete")
        {:next_state, :complete, data}

      {:error, _reason} ->
        # Tests failed, transition back to executing so Lead can remediate
        Logger.info(
          "[Lead:#{data.lead_id}] Testing failed, transitioning back to :executing for remediation"
        )

        {:next_state, :executing, data}
    end
  end

  defp handle_runner_completion_transition(_state, _remaining_tasks, _result, data) do
    {:keep_state, data}
  end

  defp spawn_testing_runner(data) do
    Logger.info("[Lead:#{data.lead_id}] Spawning testing Runner")

    instructions = """
    Verify the deliverable by running compile checks and tests.

    **Worktree path:** #{data.worktree_path}

    Run the project's test suite and report results.
    """

    context = build_runner_context(data)

    opts = %{
      job_id: data.session_id,
      config: data.config,
      worktree_path: data.worktree_path,
      rate_limiter_pid: data.rate_limiter_pid
    }

    task =
      Task.Supervisor.async_nolink(
        data.runner_supervisor,
        fn -> Runner.run(:testing, instructions, context, opts) end
      )

    # Get timeout from config
    timeout = Map.get(data.config, :job_runner_timeout, 300_000)

    # Set up timeout enforcement
    timeout_ref = Process.send_after(self(), {:runner_timeout, task.ref}, timeout)

    # Track with timeout enforcement
    runner_info = %{
      task: task,
      task_description: "testing runner",
      runner_type: :testing,
      pid: task.pid,
      monitor_ref: task.ref,
      timeout_ref: timeout_ref,
      started_at: System.monotonic_time(:millisecond)
    }

    runner_tasks = Map.put(data.runner_tasks, task.ref, runner_info)
    Map.put(data, :runner_tasks, runner_tasks)
  end

  defp build_runner_context(data) do
    """
    You are a Runner executing a task for Lead #{data.lead_id}.

    **Deliverable:** #{data.deliverable[:name]}
    **Worktree path:** #{data.worktree_path}

    Execute the instructions provided and return your results.
    """
  end

  defp send_to_foreman(data, type, content, metadata) do
    GenServer.cast(data.foreman_pid, {:lead_message, type, content, metadata})
  end
end
