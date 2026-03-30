defmodule Deft.Job.Foreman do
  @moduledoc """
  Foreman orchestrates job execution using a gen_statem with 7 pure orchestration states.

  The v0.7 redesign splits the Foreman into two processes:
  - Foreman (this module): Pure orchestration gen_statem managing job lifecycle
  - ForemanAgent: Standard Deft.Agent that does LLM reasoning

  ## Job Phase States

  - `:asking` — ForemanAgent asks clarifying questions before planning
  - `:planning` — ForemanAgent analyzes request and determines research needs
  - `:researching` — Spawns research Runners in parallel
  - `:decomposing` — ForemanAgent submits plan, presents to user for approval
  - `:executing` — Spawns Leads, monitors progress, handles steering
  - `:verifying` — Runs verification Runner (tests + review)
  - `:complete` — Squash-merges work, reports, cleans up

  ## Communication

  **Foreman → ForemanAgent:** Via `Deft.Agent.prompt/2`
  **ForemanAgent → Foreman:** Via orchestration tools that send `{:agent_action, action, payload}` messages
  **Leads → Foreman:** Via `{:lead_message, type, content, metadata}` messages
  **User → Foreman:** Via `{:prompt, text}` casts
  """

  @behaviour :gen_statem

  alias Deft.Git.Job, as: GitJob
  alias Deft.Job.LeadSupervisor
  alias Deft.Job.RateLimiter
  alias Deft.Job.Runner
  alias Deft.Project
  alias Deft.Store

  require Logger

  # Client API

  @doc """
  Starts the Foreman gen_statem.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:prompt` — Required. Initial user prompt/issue.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:runner_supervisor` — Required. PID/name of Task.Supervisor for Foreman's Runners.
  - `:working_dir` — Optional. Working directory for the project (defaults to File.cwd!()).
  - `:foreman_agent_pid` — Optional. PID of the ForemanAgent (will be set by supervisor).
  - `:cli_pid` — Optional. PID of CLI process for direct user interaction.
  - `:site_log_pid` — Optional. PID of the Store site log instance (if not provided, will look up by name).
  - `:name` — Optional. Name for the gen_statem process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    prompt = Keyword.fetch!(opts, :prompt)
    rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
    runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    foreman_agent_pid = Keyword.get(opts, :foreman_agent_pid)
    cli_pid = Keyword.get(opts, :cli_pid)
    site_log_pid = Keyword.get(opts, :site_log_pid)
    name = Keyword.get(opts, :name)

    initial_data = %{
      session_id: session_id,
      config: config,
      prompt: prompt,
      rate_limiter_pid: rate_limiter_pid,
      runner_supervisor: runner_supervisor,
      working_dir: working_dir,
      foreman_agent_pid: foreman_agent_pid,
      cli_pid: cli_pid,
      site_log_pid: site_log_pid,
      leads: %{},
      lead_monitors: %{},
      research_tasks: [],
      plan: nil,
      blocked_leads: %{},
      started_leads: MapSet.new(),
      completed_leads: MapSet.new(),
      job_start_time: System.monotonic_time(:millisecond),
      cost_ceiling_reached: false
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Sets the ForemanAgent PID after the agent is started by the supervisor.
  """
  def set_foreman_agent(foreman, agent_pid) do
    :gen_statem.cast(foreman, {:set_foreman_agent, agent_pid})
  end

  @doc """
  Sends a prompt to the Foreman from the user.
  """
  def prompt(foreman, text) do
    :gen_statem.cast(foreman, {:prompt, text})
  end

  @doc """
  Approves the current work plan during decomposition phase.
  """
  def approve_plan(foreman) do
    :gen_statem.cast(foreman, :approve_plan)
  end

  @doc """
  Rejects the current work plan and requests a revision.
  """
  def reject_plan(foreman) do
    :gen_statem.cast(foreman, :reject_plan)
  end

  @doc """
  Aborts the current job.
  """
  def abort(foreman) do
    :gen_statem.cast(foreman, :abort)
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(data) do
    # Get or look up the site log instance started by Job.Supervisor
    site_log_pid =
      case data.site_log_pid do
        nil ->
          # Look up the site log by name
          site_log_name = {:via, Registry, {Deft.ProcessRegistry, {:sitelog, data.session_id}}}

          case GenServer.whereis(site_log_name) do
            nil ->
              Logger.error("Site log not found for job #{data.session_id}")
              raise "Site log not started by Job.Supervisor"

            pid ->
              pid
          end

        pid ->
          pid
      end

    data = Map.put(data, :site_log_pid, site_log_pid)

    Logger.info("Foreman started for job #{data.session_id}")

    # Start in :asking phase if auto-approve is not set, otherwise skip to :planning
    auto_approve = Map.get(data.config, :auto_approve_all, false)
    initial_state = if auto_approve, do: :planning, else: :asking

    {:ok, initial_state, data}
  end

  @impl :gen_statem
  def handle_event(:enter, _old_state, :asking, data) do
    Logger.info("Foreman entering :asking phase")

    # Subscribe to ForemanAgent events to receive text responses
    if data.foreman_agent_pid do
      case Registry.register(Deft.Registry, {:session, "#{data.session_id}-foreman"}, []) do
        {:ok, _pid} ->
          Logger.debug("Foreman subscribed to ForemanAgent events")

        {:error, {:already_registered, _pid}} ->
          Logger.debug("Foreman already subscribed to ForemanAgent events")
      end

      Deft.Agent.prompt(data.foreman_agent_pid, data.prompt)
    else
      Logger.warning("ForemanAgent not yet available, will prompt when set")
    end

    # Initialize text accumulation buffer and Q&A history for asking phase
    data =
      data
      |> Map.put(:asking_text_buffer, "")
      |> Map.put(:qa_history, [])

    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, :planning, data) do
    Logger.info("Foreman entering :planning phase")

    # In planning, ForemanAgent analyzes the request and calls request_research tool
    # For now, this is a stub until ForemanAgent and tools are implemented
    if data.foreman_agent_pid do
      context = build_planning_context(data)
      Deft.Agent.prompt(data.foreman_agent_pid, context)
    end

    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :researching, data) do
    Logger.info("Foreman entering :researching phase")

    research_tasks = Map.get(data, :research_tasks, [])

    if length(research_tasks) > 0 do
      # Trigger collection via internal event so Foreman process collects results
      # (Task.yield must be called from the process that owns the tasks)
      {:keep_state_and_data, {:next_event, :internal, :collect_research}}
    else
      # No research tasks, skip to decomposing
      Logger.warning("No research tasks to execute")
      {:next_state, :decomposing, data}
    end
  end

  def handle_event(:internal, :collect_research, :researching, data) do
    research_timeout = Map.get(data.config, :job_research_timeout, 120_000)
    research_tasks = Map.get(data, :research_tasks, [])

    # Collect results directly in the Foreman process (task owner)
    collect_research_results(research_tasks, research_timeout, data)

    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :decomposing, data) do
    Logger.info("Foreman entering :decomposing phase - waiting for plan approval")
    # Present plan to user, wait for approval
    # For now, stub implementation

    # Check if auto-approve is enabled - skip plan approval in non-interactive/auto-approve mode
    auto_approve = Map.get(data.config, :auto_approve_all, false)

    if auto_approve do
      Logger.info("Auto-approving plan (--auto-approve-all is set)")

      # Save plan to persistence
      if data.plan do
        jobs_dir = Project.jobs_dir(data.working_dir)
        plan_path = Path.join([jobs_dir, data.session_id, "plan.json"])
        File.write!(plan_path, Jason.encode!(data.plan))
      end

      {:next_state, :executing, data}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:enter, _old_state, :executing, _data) do
    Logger.info("Foreman entering :executing phase")
    # Leads will be spawned based on the approved plan
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :verifying, _data) do
    Logger.info("Foreman entering :verifying phase")
    # Spawn verification Runner
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :complete, _data) do
    Logger.info("Foreman entering :complete phase")
    # Squash-merge all work, report summary, cleanup
    :keep_state_and_data
  end

  # Set ForemanAgent PID
  def handle_event(:cast, {:set_foreman_agent, agent_pid}, state, data) do
    Logger.debug("ForemanAgent PID set: #{inspect(agent_pid)}")
    data = Map.put(data, :foreman_agent_pid, agent_pid)

    # If we're in :asking and didn't send the initial prompt yet, subscribe and send it now
    if state == :asking and data.prompt do
      case Registry.register(Deft.Registry, {:session, "#{data.session_id}-foreman"}, []) do
        {:ok, _pid} ->
          Logger.debug("Foreman subscribed to ForemanAgent events")

        {:error, {:already_registered, _pid}} ->
          Logger.debug("Foreman already subscribed to ForemanAgent events")
      end

      Deft.Agent.prompt(agent_pid, data.prompt)
    end

    {:keep_state, data}
  end

  # Handle agent events from ForemanAgent during asking phase
  def handle_event(:info, {:agent_event, {:text_delta, delta}}, :asking, data) do
    # Accumulate text from ForemanAgent
    current_buffer = Map.get(data, :asking_text_buffer, "")
    new_buffer = current_buffer <> delta
    data = Map.put(data, :asking_text_buffer, new_buffer)
    {:keep_state, data}
  end

  def handle_event(:info, {:agent_event, {:state_change, :idle}}, :asking, data) do
    # ForemanAgent completed a message - relay accumulated text to user
    text = Map.get(data, :asking_text_buffer, "")

    if text != "" do
      relay_to_user(data, text)

      # Record agent question in Q&A history
      qa_history = Map.get(data, :qa_history, [])

      updated_qa =
        qa_history ++
          [%{role: :agent, content: text, timestamp: System.system_time(:millisecond)}]

      # Clear buffer for next question
      data =
        data
        |> Map.put(:asking_text_buffer, "")
        |> Map.put(:qa_history, updated_qa)

      {:keep_state, data}
    else
      :keep_state_and_data
    end
  end

  # Handle agent actions from ForemanAgent orchestration tools
  def handle_event(:info, {:agent_action, :ready_to_plan}, :asking, data) do
    Logger.info("ForemanAgent ready to plan, transitioning to :planning")
    # Unsubscribe from ForemanAgent events when leaving :asking
    Registry.unregister(Deft.Registry, {:session, "#{data.session_id}-foreman"})
    {:next_state, :planning, data}
  end

  def handle_event(:info, {:agent_action, :research, topics}, :planning, data) do
    Logger.info("ForemanAgent requested research on topics: #{inspect(topics)}")

    # Spawn research Runners in parallel
    research_tasks =
      Enum.map(topics, fn topic ->
        Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
          run_research_runner(topic, data)
        end)
      end)

    # Store tasks and transition to researching phase
    data = Map.put(data, :research_tasks, research_tasks)
    {:next_state, :researching, data}
  end

  def handle_event(:info, {:agent_action, :plan, plan_data}, :planning, data) do
    deliverables = Map.get(plan_data, :deliverables, [])
    dependencies = Map.get(plan_data, :dependencies, [])
    rationale = Map.get(plan_data, :rationale, "")

    Logger.info(
      "ForemanAgent submitted plan with #{length(deliverables)} deliverables (from :planning state)"
    )

    # Normalize deliverables and dependencies to use atom keys
    normalized_deliverables = Enum.map(deliverables, &normalize_deliverable_keys/1)
    normalized_dependencies = Enum.map(dependencies, &normalize_dependency_keys/1)

    # Store the full plan data
    full_plan = %{
      deliverables: normalized_deliverables,
      dependencies: normalized_dependencies,
      rationale: rationale
    }

    data = Map.put(data, :plan, full_plan)

    # Write plan to site log
    if data.site_log_pid do
      Store.write(data.site_log_pid, "plan", full_plan)
    end

    # Present plan to user for approval
    present_plan_to_user(data, normalized_deliverables)

    {:next_state, :decomposing, data}
  end

  def handle_event(:info, {:agent_action, :plan, plan_data}, :researching, data) do
    deliverables = Map.get(plan_data, :deliverables, [])
    dependencies = Map.get(plan_data, :dependencies, [])
    rationale = Map.get(plan_data, :rationale, "")

    Logger.info("ForemanAgent submitted plan with #{length(deliverables)} deliverables")

    # Normalize deliverables and dependencies to use atom keys
    normalized_deliverables = Enum.map(deliverables, &normalize_deliverable_keys/1)
    normalized_dependencies = Enum.map(dependencies, &normalize_dependency_keys/1)

    # Store the full plan data
    full_plan = %{
      deliverables: normalized_deliverables,
      dependencies: normalized_dependencies,
      rationale: rationale
    }

    data = Map.put(data, :plan, full_plan)

    # Write plan to site log
    if data.site_log_pid do
      Store.write(data.site_log_pid, "plan", full_plan)
    end

    # Present plan to user for approval
    present_plan_to_user(data, normalized_deliverables)

    {:next_state, :decomposing, data}
  end

  def handle_event(:info, {:agent_action, :spawn_lead, deliverable_info}, :executing, data) do
    # Look up full deliverable from plan by ID
    deliverable_id = Map.get(deliverable_info, :id)
    additional_context = Map.get(deliverable_info, :context, "")

    case find_deliverable_by_id(data.plan, deliverable_id) do
      nil ->
        Logger.error("Cannot spawn Lead: deliverable '#{deliverable_id}' not found in plan")
        :keep_state_and_data

      deliverable ->
        handle_spawn_lead_with_deliverable(
          deliverable,
          deliverable_id,
          additional_context,
          data
        )
    end
  end

  def handle_event(:info, {:agent_action, :unblock_lead, lead_id, contract}, :executing, data) do
    Logger.info("ForemanAgent unblocking Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("Cannot unblock Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          # Send contract to Lead
          send(lead.pid, {:foreman_contract, contract})
          Logger.info("Sent contract to Lead #{lead_id}")

          # Remove from blocked_leads if present
          data = Map.update!(data, :blocked_leads, &Map.delete(&1, lead_id))
          {:keep_state, data}
        else
          Logger.warning("Cannot unblock Lead #{lead_id}: Lead PID not available")
          :keep_state_and_data
        end
    end
  end

  def handle_event(:info, {:agent_action, :steer_lead, lead_id, content}, :executing, data) do
    Logger.info("ForemanAgent steering Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("Cannot steer Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          # Send steering to Lead
          send(lead.pid, {:foreman_steering, content})
          Logger.info("Sent steering to Lead #{lead_id}")
          :keep_state_and_data
        else
          Logger.warning("Cannot steer Lead #{lead_id}: Lead PID not available")
          :keep_state_and_data
        end
    end
  end

  def handle_event(:info, {:agent_action, :abort_lead, lead_id}, :executing, data) do
    Logger.info("ForemanAgent aborting Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("Cannot abort Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          do_abort_lead(lead_id, lead.pid, data)
        else
          Logger.warning("Cannot abort Lead #{lead_id}: Lead PID not available")
          :keep_state_and_data
        end
    end
  end

  # Handle user prompts
  def handle_event(:cast, {:prompt, text}, :asking, data) do
    Logger.debug("User answer received in asking phase: #{text}")

    # Check for /correct command and promote to site log if present
    handle_correct_command(text, data)

    # Record user answer in Q&A history
    qa_history = Map.get(data, :qa_history, [])

    updated_qa =
      qa_history ++ [%{role: :user, content: text, timestamp: System.system_time(:millisecond)}]

    data = Map.put(data, :qa_history, updated_qa)

    # Forward user input to ForemanAgent
    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, text)
    end

    {:keep_state, data}
  end

  def handle_event(:cast, {:prompt, text}, state, data)
      when state in [:executing, :planning, :researching, :decomposing] do
    Logger.debug("User prompt received in #{state}: #{text}")

    # Check for /correct command and promote to site log if present
    handle_correct_command(text, data)

    # Build structured context including current job state
    context = build_user_prompt_context(text, state, data)

    # Forward with context to ForemanAgent
    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, context)
    end

    :keep_state_and_data
  end

  def handle_event(:cast, {:prompt, text}, state, data) do
    Logger.debug("User prompt received in #{state}: #{text}")

    # Check for /correct command and promote to site log if present
    handle_correct_command(text, data)

    # For other states, just forward as-is
    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, text)
    end

    :keep_state_and_data
  end

  # Plan approval
  def handle_event(:cast, :approve_plan, :decomposing, data) do
    Logger.info("Plan approved, transitioning to :executing")

    # Save plan to persistence
    if data.plan do
      jobs_dir = Project.jobs_dir(data.working_dir)
      plan_path = Path.join([jobs_dir, data.session_id, "plan.json"])
      File.write!(plan_path, Jason.encode!(data.plan))
    end

    {:next_state, :executing, data}
  end

  def handle_event(:cast, :reject_plan, :decomposing, data) do
    Logger.info("Plan rejected, returning to :planning")
    {:next_state, :planning, data}
  end

  # Abort
  def handle_event(:cast, :abort, _state, data) do
    Logger.info("Job aborted")
    # Cleanup and stop
    cleanup(data)
    {:stop, :normal, data}
  end

  # Handle Lead messages
  def handle_event(:info, {:lead_message, type, content, metadata}, state, data) do
    Logger.debug("Lead message received: #{type}")

    # Forward to ForemanAgent with structured context
    if data.foreman_agent_pid do
      message = build_lead_message_context(type, content, metadata, state, data)
      Deft.Agent.prompt(data.foreman_agent_pid, message)
    end

    # Auto-promote certain message types to site log
    promote_lead_message_to_site_log(type, content, metadata, data)

    # Handle Lead completion - remove from tracking and check for transition to verifying
    handle_lead_completion(type, metadata, state, data)
  end

  # Handle Lead process DOWN messages
  def handle_event(:info, {:DOWN, ref, :process, pid, reason}, state, data) do
    case find_lead_by_monitor(data.lead_monitors, ref) do
      {:ok, lead_id} ->
        Logger.warning("Lead #{lead_id} (#{inspect(pid)}) crashed: #{inspect(reason)}")
        do_handle_lead_crash(lead_id, state, data)

      :not_found ->
        # Monitor might be for another process (e.g., Runner)
        :keep_state_and_data
    end
  end

  # Handle cost warning from RateLimiter
  def handle_event(:info, {:rate_limiter, :cost_warning, cost}, _state, data) do
    Logger.info("Cost warning: $#{Float.round(cost, 2)} (approaching cost ceiling)")

    # Notify user about cost warning
    message = """
    ⚠️  Cost Warning: This job has reached $#{Float.round(cost, 2)} and is approaching the cost ceiling.
    """

    notify_user(data, :cost_warning, message)

    :keep_state_and_data
  end

  # Handle cost ceiling reached from RateLimiter
  def handle_event(:info, {:rate_limiter, :cost_ceiling_reached, cost}, _state, data) do
    Logger.warning("Cost ceiling reached: $#{Float.round(cost, 2)}, execution paused")

    # Notify user and wait for approval
    message = """
    🛑 Cost Ceiling Reached

    This job has reached $#{Float.round(cost, 2)} and execution has been paused.

    The RateLimiter has paused all LLM requests until you approve continued spending.

    To continue: Send 'approve' or use :approve_continued_spending
    To abort: Send 'abort' or use :abort
    """

    notify_user(data, :cost_ceiling_reached, message)

    # Set flag to track that we're waiting for cost approval
    updated_data = %{data | cost_ceiling_reached: true}
    {:keep_state, updated_data}
  end

  # Handle user approval for continued spending
  def handle_event(:cast, :approve_continued_spending, _state, data) do
    Logger.info("User approved continued spending, notifying RateLimiter")

    # Call RateLimiter to reset cost ceiling flag
    RateLimiter.approve_continued_spending(data.session_id)

    message = "✅ Continued spending approved. Execution resumed."
    notify_user(data, :spending_approved, message)

    # Reset flag
    updated_data = %{data | cost_ceiling_reached: false}
    {:keep_state, updated_data}
  end

  # Catch-all for unhandled events
  def handle_event(event_type, event_content, state, _data) do
    Logger.warning(
      "Unhandled event in #{state}: #{inspect(event_type)} #{inspect(event_content)}"
    )

    :keep_state_and_data
  end

  @impl :gen_statem
  def terminate(reason, state, data) do
    Logger.info("Foreman terminating in #{state}: #{inspect(reason)}")
    cleanup(data)
    :ok
  end

  # Private functions

  defp relay_to_user(data, text) do
    Logger.info("Foreman relaying ForemanAgent question to user")

    # Send to CLI if available
    if data.cli_pid do
      send(data.cli_pid, {:foreman_question, text})
    end

    # Broadcast to Registry for web UI and other subscribers
    Registry.dispatch(Deft.Registry, {:job, data.session_id}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:foreman_question, text})
      end
    end)
  end

  defp build_planning_context(data) do
    qa_section = format_qa_history(Map.get(data, :qa_history, []))

    """
    Job: #{data.session_id}
    Initial Request: #{data.prompt}
    #{qa_section}

    You've completed the asking phase. Now analyze this request with the full context from Q&A and determine what research is needed before planning the work decomposition.

    Use the `request_research` tool to specify research topics.
    """
  end

  defp format_qa_history([]), do: ""

  defp format_qa_history(qa_history) do
    exchanges =
      Enum.map(qa_history, fn entry ->
        role_label = if entry.role == :agent, do: "You asked", else: "User answered"
        "#{role_label}: #{entry.content}"
      end)
      |> Enum.join("\n\n")

    """

    ## Clarification Q&A

    #{exchanges}
    """
  end

  defp build_lead_message_context(type, content, metadata, state, data) do
    lead_id = Map.get(metadata, :lead_id, "unknown")
    lead_name = Map.get(metadata, :lead_name, "Unknown Lead")
    leads_status = format_leads_status(data.leads)
    contracts_info = format_contracts_from_sitelog(data.site_log_pid)

    """
    ## Lead Update

    **Type:** #{type}
    **From:** #{lead_name} (#{lead_id})
    **Job Phase:** #{state}

    ### Message Content

    #{inspect(content, pretty: true, limit: :infinity)}

    ### Metadata

    #{inspect(metadata, pretty: true)}

    ## Current Job State

    ### Active Leads

    #{leads_status}
    #{contracts_info}

    ### What to do

    Based on this update, decide if you need to:
    - Spawn a new Lead (use `spawn_lead`)
    - Unblock a waiting Lead (use `unblock_lead`)
    - Steer this or another Lead (use `steer_lead`)
    - Abort a Lead that's stuck (use `abort_lead`)
    - Or simply acknowledge and continue monitoring
    """
  end

  defp format_leads_status(leads) when map_size(leads) == 0 do
    "No other Leads are currently active."
  end

  defp format_leads_status(leads) do
    Enum.map(leads, fn {id, lead_info} ->
      status = Map.get(lead_info, :status, :unknown)
      deliverable = Map.get(lead_info, :deliverable, %{})
      deliverable_name = Map.get(deliverable, :name, "Unnamed")
      "- Lead #{id}: #{deliverable_name} (#{status})"
    end)
    |> Enum.join("\n")
  end

  defp format_contracts_from_sitelog(nil), do: ""

  defp format_contracts_from_sitelog(site_log_pid) do
    tid = Store.tid(site_log_pid)
    all_keys = Store.keys(tid)
    contract_keys = Enum.filter(all_keys, &String.starts_with?(&1, "contract-"))

    format_contract_list(tid, contract_keys)
  end

  defp format_contract_list(_tid, []), do: ""

  defp format_contract_list(tid, contract_keys) do
    formatted_contracts =
      Enum.map(contract_keys, fn key ->
        case Store.read(tid, key) do
          {:ok, entry} ->
            content = get_in(entry, [:value, :content]) || "No content"
            "- #{inspect(content)}"

          _other ->
            "- [Could not read contract #{key}]"
        end
      end)
      |> Enum.join("\n")

    """

    ## Contracts Published

    #{formatted_contracts}
    """
  end

  defp build_user_prompt_context(user_text, state, data) do
    leads_summary = format_leads_status(Map.get(data, :leads, %{}))
    plan_summary = format_plan_summary(data.plan)

    """
    ## User Message

    #{user_text}

    ## Current Job Context

    **Phase:** #{state}
    **Job ID:** #{data.session_id}

    ### Work Plan

    #{plan_summary}

    ### Lead Status

    #{leads_summary}

    ### Response Guidance

    The user may be:
    - Asking for status (provide a summary)
    - Providing additional context (incorporate it into your reasoning)
    - Requesting a change in direction (use steering tools as needed)
    - Asking to abort something (use `abort_lead` if needed)

    Process their message and respond or take action as appropriate.
    """
  end

  defp format_plan_summary(nil), do: "No plan has been created yet."

  defp format_plan_summary(plan) when is_map(plan) do
    deliverables = Map.get(plan, :deliverables, [])
    format_plan_summary(deliverables)
  end

  defp format_plan_summary(plan) when not is_list(plan),
    do: "Plan available but format unexpected."

  defp format_plan_summary(plan) do
    deliverable_list =
      Enum.map(plan, fn deliverable ->
        name = Map.get(deliverable, :name, "Unnamed")
        desc = Map.get(deliverable, :description, "No description")
        "- #{name}: #{desc}"
      end)
      |> Enum.join("\n")

    """
    Current Work Plan:
    #{deliverable_list}
    """
  end

  defp find_lead_by_monitor(monitors, ref) do
    case Enum.find(monitors, fn {_id, monitor_ref} -> monitor_ref == ref end) do
      {lead_id, _ref} -> {:ok, lead_id}
      nil -> :not_found
    end
  end

  defp find_deliverable_by_id(nil, _id), do: nil

  defp find_deliverable_by_id(plan, deliverable_id) when is_map(plan) do
    # Handle plan as map with :deliverables key (current format from submit_plan)
    deliverables = Map.get(plan, :deliverables, [])
    find_in_deliverable_list(deliverables, deliverable_id)
  end

  defp find_deliverable_by_id(plan, deliverable_id) when is_list(plan) do
    # Handle plan as list of deliverables (future format after submit_plan fix)
    find_in_deliverable_list(plan, deliverable_id)
  end

  defp find_in_deliverable_list(deliverables, deliverable_id) do
    Enum.find(deliverables, fn d ->
      Map.get(d, :id) == deliverable_id || Map.get(d, "id") == deliverable_id
    end)
  end

  defp handle_spawn_lead_with_deliverable(
         deliverable,
         deliverable_id,
         additional_context,
         data
       ) do
    # Merge additional context from tool call
    deliverable_with_context =
      if additional_context != "" do
        Map.put(deliverable, :additional_context, additional_context)
      else
        deliverable
      end

    Logger.info("ForemanAgent requested spawning Lead for: #{inspect(deliverable[:name])}")

    # Check if Lead already started for this deliverable
    if deliverable_already_started?(data, deliverable_id) do
      Logger.warning(
        "Lead for deliverable #{deliverable_id} already started, ignoring spawn request"
      )

      :keep_state_and_data
    else
      # Generate unique Lead ID
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"

      case do_spawn_lead(lead_id, deliverable_with_context, data) do
        {:ok, updated_data} -> {:keep_state, updated_data}
        :error -> :keep_state_and_data
      end
    end
  end

  defp deliverable_already_started?(data, deliverable_id) do
    Enum.any?(Map.get(data, :leads, %{}), fn {_id, lead} ->
      Map.get(lead.deliverable, :id) == deliverable_id
    end)
  end

  defp do_spawn_lead(lead_id, deliverable, data) do
    with {:ok, worktree_path} <- create_lead_worktree(lead_id, data),
         {:ok, lead_pid} <- start_lead_process(lead_id, deliverable, worktree_path, data) do
      # Monitor the Lead process
      monitor_ref = Process.monitor(lead_pid)

      # Track Lead with monitoring
      updated_data =
        data
        |> Map.update!(:started_leads, &MapSet.put(&1, lead_id))
        |> put_in([:leads, lead_id], %{
          deliverable: deliverable,
          status: :running,
          pid: lead_pid,
          worktree_path: worktree_path
        })
        |> put_in([:lead_monitors, lead_id], monitor_ref)

      Logger.info("Lead #{lead_id} started with PID #{inspect(lead_pid)} at #{worktree_path}")
      {:ok, updated_data}
    else
      {:error, reason} ->
        Logger.error("Failed to spawn Lead #{lead_id}: #{inspect(reason)}")
        :error
    end
  end

  defp create_lead_worktree(lead_id, data) do
    GitJob.create_lead_worktree(
      lead_id: lead_id,
      job_id: data.session_id,
      working_dir: data.working_dir
    )
  end

  defp start_lead_process(lead_id, deliverable, worktree_path, data) do
    site_log_name = {:via, Registry, {Deft.ProcessRegistry, {:sitelog, data.session_id}}}

    runner_supervisor_name =
      {:via, Registry, {Deft.ProcessRegistry, {:runner_supervisor, lead_id}}}

    lead_opts = [
      lead_id: lead_id,
      session_id: data.session_id,
      config: data.config,
      deliverable: deliverable,
      foreman_pid: self(),
      site_log_name: site_log_name,
      rate_limiter_pid: data.rate_limiter_pid,
      worktree_path: worktree_path,
      working_dir: data.working_dir,
      runner_supervisor: runner_supervisor_name
    ]

    LeadSupervisor.start_lead(data.session_id, lead_opts)
  end

  defp do_abort_lead(lead_id, lead_pid, data) do
    # Stop Lead process
    Process.exit(lead_pid, :shutdown)
    Logger.info("Aborted Lead #{lead_id}")

    # Clean up monitor if present
    cleanup_lead_monitor(data.lead_monitors, lead_id)

    # Remove from tracking
    data =
      data
      |> Map.update!(:leads, &Map.delete(&1, lead_id))
      |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
      |> Map.update!(:blocked_leads, &Map.delete(&1, lead_id))
      |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))

    {:keep_state, data}
  end

  defp cleanup_lead_monitor(monitors, lead_id) do
    case Map.get(monitors, lead_id) do
      nil -> :ok
      monitor_ref -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp all_leads_complete?(data) do
    # All Leads are complete when the number of completed Leads equals
    # the number of deliverables in the plan.
    # This ensures we don't transition to :verifying if a Lead crashed
    # (crashed Leads are removed from started_leads but NOT added to completed_leads)
    if data.plan && data.plan.deliverables do
      expected_count = length(data.plan.deliverables)
      actual_count = MapSet.size(data.completed_leads)
      actual_count == expected_count
    else
      # Fallback: if no plan exists yet, check if started_leads is empty
      MapSet.size(data.started_leads) == 0
    end
  end

  defp handle_correct_command(text, data) do
    # Parse /correct command and promote to site log if detected
    case String.trim(text) do
      "/correct " <> message when byte_size(message) > 0 ->
        Logger.info("User correction detected: #{message}")
        metadata = %{source: :user}
        promote_lead_message_to_site_log(:correction, message, metadata, data)

      _ ->
        :ok
    end
  end

  defp promote_lead_message_to_site_log(type, content, metadata, data) do
    if type in [:contract, :decision, :correction, :critical_finding] and data.site_log_pid do
      # Generate unique key with type prefix
      unique_id = :erlang.unique_integer([:positive])
      key = "#{type}-#{unique_id}"

      Store.write(
        data.site_log_pid,
        key,
        content,
        Map.merge(metadata, %{
          type: type,
          timestamp: System.system_time(:millisecond)
        })
      )
    end
  end

  defp handle_lead_completion(type, metadata, state, data) do
    if type == :complete do
      lead_id = Map.get(metadata, :lead_id)
      Logger.info("Lead #{lead_id} completed, removing from started_leads")

      updated_data =
        data
        |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
        |> Map.update!(:completed_leads, &MapSet.put(&1, lead_id))

      # Check if all Leads are complete and transition to :verifying
      if state == :executing and all_leads_complete?(updated_data) do
        Logger.info("All Leads complete, transitioning to :verifying")
        {:next_state, :verifying, updated_data}
      else
        {:keep_state, updated_data}
      end
    else
      :keep_state_and_data
    end
  end

  defp do_handle_lead_crash(lead_id, _state, data) do
    # Clean up the crashed Lead's worktree
    GitJob.cleanup_lead_worktree(
      lead_id: lead_id,
      working_dir: data.working_dir
    )

    Logger.info("Cleaned up worktree for crashed Lead #{lead_id}")

    # Clean up monitor
    cleanup_lead_monitor(data.lead_monitors, lead_id)

    # Remove from tracking
    updated_data =
      data
      |> Map.update!(:leads, &Map.delete(&1, lead_id))
      |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
      |> Map.update!(:blocked_leads, &Map.delete(&1, lead_id))
      |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))

    # DO NOT transition to :verifying after a crash - a crashed Lead is not a completed Lead
    # The job should remain in its current state and let the Foreman/user handle the failure
    {:keep_state, updated_data}
  end

  defp run_research_runner(topic, data) do
    runner_model = Map.get(data.config, :job_research_runner_model, "claude-sonnet-4")

    runner_config = %{
      model: runner_model,
      provider: Deft.Provider.Anthropic,
      temperature: 0.7
    }

    instructions = """
    Research the following topic in the codebase:

    #{topic}

    Provide findings that will help plan the implementation.
    """

    context = """
    Working directory: #{data.working_dir}
    Job: #{data.session_id}
    """

    opts = %{
      job_id: data.session_id,
      config: runner_config,
      worktree_path: data.working_dir
    }

    case Runner.run(:research, instructions, context, opts) do
      {:ok, output} ->
        %{topic: topic, status: :success, findings: output}

      {:error, reason} ->
        %{topic: topic, status: :error, error: reason}
    end
  end

  defp collect_research_results(tasks, timeout, data) do
    results =
      Enum.map(tasks, fn task ->
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, result} -> result
          nil -> %{topic: "unknown", status: :timeout, error: "Research task timed out"}
          {:exit, reason} -> %{topic: "unknown", status: :error, error: inspect(reason)}
        end
      end)

    # Format results and send to ForemanAgent
    findings_summary = format_research_findings(results)

    if data.foreman_agent_pid do
      prompt = """
      Research complete. Here are the findings:

      #{findings_summary}

      Based on these findings, create a work decomposition plan.
      """

      Deft.Agent.prompt(data.foreman_agent_pid, prompt)
    else
      Logger.warning("ForemanAgent not available to receive research results")
    end
  end

  defp format_research_findings(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, idx} ->
      case result.status do
        :success ->
          """
          ## Finding #{idx}: #{result.topic}

          #{result.findings}
          """

        :error ->
          """
          ## Finding #{idx}: #{result.topic}

          **Error:** #{result.error}
          """

        :timeout ->
          """
          ## Finding #{idx}: #{result.topic}

          **Timeout:** Research task exceeded time limit
          """
      end
    end)
    |> Enum.join("\n\n")
  end

  defp present_plan_to_user(data, deliverables) do
    plan_summary = format_plan_for_user(deliverables)

    Logger.info("Presenting plan to user:\n#{plan_summary}")

    # Send to CLI if available
    if data.cli_pid do
      send(data.cli_pid, {:foreman_plan, plan_summary, deliverables})
    end

    # Broadcast to Registry for web UI and other subscribers
    Registry.dispatch(Deft.Registry, {:job, data.session_id}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:foreman_plan, plan_summary, deliverables})
      end
    end)
  end

  defp notify_user(data, notification_type, message) do
    # Send to CLI if available
    if data.cli_pid do
      send(data.cli_pid, {:foreman_notification, notification_type, message})
    end

    # Broadcast to Registry for web UI and other subscribers
    Registry.dispatch(Deft.Registry, {:job, data.session_id}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:foreman_notification, notification_type, message})
      end
    end)
  end

  defp format_plan_for_user(deliverables) do
    """
    # Work Plan

    The following deliverables have been identified:

    #{Enum.map_join(deliverables, "\n\n", &format_deliverable/1)}

    Please review and approve or reject this plan.
    """
  end

  defp format_deliverable(deliverable) do
    """
    ## #{deliverable[:name] || "Unnamed Deliverable"}

    #{deliverable[:description] || "No description"}

    Dependencies: #{inspect(deliverable[:dependencies] || [])}
    """
  end

  # Normalize deliverable keys from strings to atoms
  defp normalize_deliverable_keys(deliverable) when is_map(deliverable) do
    id = Map.get(deliverable, "id")

    %{
      id: id,
      name: id,
      description: Map.get(deliverable, "description"),
      files: Map.get(deliverable, "files", []),
      estimated_complexity: Map.get(deliverable, "estimated_complexity")
    }
  end

  # Normalize dependency keys from strings to atoms
  defp normalize_dependency_keys(dependency) when is_map(dependency) do
    %{
      from: Map.get(dependency, "from"),
      to: Map.get(dependency, "to"),
      contract: Map.get(dependency, "contract")
    }
  end

  defp cleanup(data) do
    # Stop site log
    if data.site_log_pid && Process.alive?(data.site_log_pid) do
      Store.cleanup(data.site_log_pid)
    end

    # Stop all Leads (when implemented)
    # Cleanup worktrees (when implemented)

    :ok
  end
end
