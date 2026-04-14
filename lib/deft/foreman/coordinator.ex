defmodule Deft.Foreman.Coordinator do
  @moduledoc """
  Foreman.Coordinator orchestrates job execution using a gen_statem with 7 pure orchestration states.

  The v0.7 redesign splits the Foreman into two processes:
  - Foreman.Coordinator (this module): Pure orchestration gen_statem managing job lifecycle
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

  **Foreman.Coordinator → ForemanAgent:** Via `Deft.Agent.prompt/2`
  **ForemanAgent → Foreman.Coordinator:** Via orchestration tools that send `{:agent_action, action, payload}` messages
  **Leads → Foreman.Coordinator:** Via `{:lead_message, type, content, metadata}` messages
  **User → Foreman.Coordinator:** Via `{:prompt, text}` casts
  """

  @behaviour :gen_statem

  alias Deft.Git.Job, as: GitJob
  alias Deft.Foreman
  alias Deft.LeadSupervisor
  alias Deft.RateLimiter
  alias Deft.Job.Runner
  alias Deft.Project
  alias Deft.Session.Store, as: SessionStore
  alias Deft.Store

  require Logger

  # Client API

  @doc """
  Starts the Foreman.Coordinator gen_statem.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:prompt` — Required. Initial user prompt/issue.
  - `:runner_supervisor` — Required. PID/name of Task.Supervisor for Foreman's Runners.
  - `:working_dir` — Optional. Working directory for the project (defaults to File.cwd!()).
  - `:foreman_agent_pid` — Optional. Via-tuple or PID of the ForemanAgent (will be set by supervisor).
  - `:cli_pid` — Optional. PID of CLI process for direct user interaction.
  - `:name` — Optional. Name for the gen_statem process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    prompt = Keyword.fetch!(opts, :prompt)
    runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    foreman_agent_pid = Keyword.get(opts, :foreman_agent_pid)
    cli_pid = Keyword.get(opts, :cli_pid)
    name = Keyword.get(opts, :name)

    initial_data = %{
      session_id: session_id,
      config: config,
      prompt: prompt,
      runner_supervisor: runner_supervisor,
      working_dir: working_dir,
      foreman_agent_pid: foreman_agent_pid,
      cli_pid: cli_pid,
      leads: %{},
      lead_monitors: %{},
      foreman_agent_monitor_ref: nil,
      research_tasks: [],
      plan: nil,
      blocked_leads: %{},
      started_leads: MapSet.new(),
      completed_leads: MapSet.new(),
      failed_leads: MapSet.new(),
      deliverable_outcomes: %{},
      job_start_time: System.monotonic_time(:millisecond),
      cost_ceiling_reached: false,
      lead_message_buffer: [],
      lead_message_timer: nil,
      buffer_start_time: nil,
      pending_crash_decisions: %{},
      foreman_agent_restart_count: 0,
      foreman_agent_restarting: false,
      lead_modified_files: %{}
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Sets the ForemanAgent after the agent is started by the supervisor.

  Accepts either a via-tuple (production) or raw PID (tests).
  """
  def set_foreman_agent(foreman, agent_name_or_pid) do
    :gen_statem.cast(foreman, {:set_foreman_agent, agent_name_or_pid})
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
    data =
      data
      |> setup_foreman_agent_monitoring()
      |> setup_store_monitoring()
      |> setup_rate_limiter_monitoring()

    Logger.info("#{log_prefix(data)} Foreman started for job #{data.session_id}: #{data.prompt}")

    # Start in :asking phase if auto-approve is not set, otherwise skip to :planning
    auto_approve = Map.get(data.config, :auto_approve_all, false)
    initial_state = if auto_approve, do: :planning, else: :asking

    {:ok, initial_state, data}
  end

  # Private helper to get the site log registered name
  defp site_log_name(data) do
    {:via, Registry, {Deft.ProcessRegistry, {:sitelog, data.session_id}}}
  end

  # Private helper to get the rate limiter registered name
  defp rate_limiter_name(data) do
    {:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}}
  end

  # Private helper to set up ForemanAgent monitoring
  defp setup_foreman_agent_monitoring(data) do
    case data.foreman_agent_pid do
      nil ->
        Logger.warning("#{log_prefix(data)} ForemanAgent PID not provided during init")
        data

      name_or_pid ->
        # Resolve to PID for monitoring, but keep the via-tuple/name for communication
        pid = resolve_agent_pid(name_or_pid)

        if pid do
          monitor_ref = Process.monitor(pid)

          Logger.debug(
            "#{log_prefix(data)} Monitoring ForemanAgent with ref: #{inspect(monitor_ref)}"
          )

          # Keep the via-tuple in foreman_agent_pid for Deft.Agent.prompt/2 calls
          data
          |> Map.put(:foreman_agent_monitor_ref, monitor_ref)
        else
          Logger.warning(
            "#{log_prefix(data)} Could not resolve ForemanAgent name to PID: #{inspect(name_or_pid)}"
          )

          data
        end
    end
  end

  # Private helper to set up Store monitoring
  defp setup_store_monitoring(data) do
    store_name = site_log_name(data)
    pid = resolve_agent_pid(store_name)

    if pid do
      monitor_ref = Process.monitor(pid)

      Logger.debug("#{log_prefix(data)} Monitoring Store with ref: #{inspect(monitor_ref)}")

      Map.put(data, :store_monitor_ref, monitor_ref)
    else
      Logger.warning(
        "#{log_prefix(data)} Could not resolve Store name to PID: #{inspect(store_name)}"
      )

      data
    end
  end

  # Private helper to set up RateLimiter monitoring
  defp setup_rate_limiter_monitoring(data) do
    rate_limiter_name = rate_limiter_name(data)
    pid = resolve_agent_pid(rate_limiter_name)

    if pid do
      monitor_ref = Process.monitor(pid)

      Logger.debug("#{log_prefix(data)} Monitoring RateLimiter with ref: #{inspect(monitor_ref)}")

      Map.put(data, :rate_limiter_monitor_ref, monitor_ref)
    else
      Logger.warning(
        "#{log_prefix(data)} Could not resolve RateLimiter name to PID: #{inspect(rate_limiter_name)}"
      )

      data
    end
  end

  # Resolve a registered name or PID to an actual PID
  defp resolve_agent_pid(pid) when is_pid(pid), do: pid
  defp resolve_agent_pid(name), do: GenServer.whereis(name)

  # Generate log prefix with job ID prefix (first 8 chars of session ID)
  defp log_prefix(data) do
    job_id_prefix = String.slice(data.session_id, 0, 8)
    "[Foreman:#{job_id_prefix}]"
  end

  @impl :gen_statem
  def handle_event(:enter, _old_state, :asking, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :asking phase")
    broadcast_job_status(:asking, data)

    # Subscribe to ForemanAgent events to receive text responses
    if data.foreman_agent_pid do
      case Registry.register(Deft.Registry, {:session, "#{data.session_id}-foreman"}, []) do
        {:ok, _pid} ->
          Logger.debug("#{log_prefix(data)} Foreman subscribed to ForemanAgent events")

        {:error, {:already_registered, _pid}} ->
          Logger.debug("#{log_prefix(data)} Foreman already subscribed to ForemanAgent events")
      end

      if data.prompt do
        Deft.Agent.prompt(data.foreman_agent_pid, data.prompt)
      end
    else
      Logger.warning("#{log_prefix(data)} ForemanAgent not yet available, will prompt when set")
    end

    # Initialize text accumulation buffer and Q&A history for asking phase
    data =
      data
      |> Map.put(:asking_text_buffer, "")
      |> Map.put(:qa_history, [])

    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, :planning, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :planning phase")
    broadcast_job_status(:planning, data)

    # Create job branch on first entry to planning (job start)
    auto_approve = Map.get(data.config, :auto_approve_all, false)

    case GitJob.create_job_branch(job_id: data.session_id, auto_approve: auto_approve) do
      {:ok, job_branch, original_branch} ->
        Logger.info(
          "#{log_prefix(data)} Created job branch: #{job_branch} (original: #{original_branch})"
        )

        updated_data =
          Map.merge(data, %{job_branch: job_branch, original_branch: original_branch})

        # In planning, ForemanAgent analyzes the request and calls request_research tool
        # For now, this is a stub until ForemanAgent and tools are implemented
        if updated_data.foreman_agent_pid do
          context = build_planning_context(updated_data)
          Deft.Agent.prompt(updated_data.foreman_agent_pid, context)
        end

        {:keep_state, updated_data}

      {:error, reason} ->
        Logger.error("#{log_prefix(data)} Failed to create job branch: #{inspect(reason)}")
        {:stop, {:shutdown, {:git_error, reason}}, data}
    end
  end

  def handle_event(:enter, _old_state, :researching, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :researching phase")
    broadcast_job_status(:researching, data)

    research_tasks = Map.get(data, :research_tasks, [])

    if length(research_tasks) > 0 do
      # Trigger collection via state_timeout so Foreman process collects results
      # (Task.yield must be called from the process that owns the tasks)
      {:keep_state_and_data, {:state_timeout, 0, :collect_research}}
    else
      # No research tasks, skip to decomposing
      Logger.warning("#{log_prefix(data)} No research tasks to execute")
      {:next_state, :decomposing, data}
    end
  end

  def handle_event(:state_timeout, :collect_research, :researching, data) do
    research_timeout = Map.get(data.config, :job_research_timeout, 120_000)
    research_tasks = Map.get(data, :research_tasks, [])

    # Collect results directly in the Foreman process (task owner)
    collect_research_results(research_tasks, research_timeout, data)

    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :decomposing, data) do
    Logger.info(
      "#{log_prefix(data)} Foreman entering :decomposing phase - waiting for plan approval"
    )

    broadcast_job_status(:decomposing, data)

    # Present plan to user, wait for approval
    # For now, stub implementation

    # Check if auto-approve is enabled - skip plan approval in non-interactive/auto-approve mode
    auto_approve = Map.get(data.config, :auto_approve_all, false)

    if auto_approve do
      Logger.info("#{log_prefix(data)} Auto-approving plan (--auto-approve-all is set)")

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

  def handle_event(:enter, _old_state, :executing, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :executing phase")
    broadcast_job_status(:executing, data)
    # Leads will be spawned based on the approved plan
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :verifying, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :verifying phase")
    broadcast_job_status(:verifying, data)

    # Spawn verification Runner
    verification_task =
      Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
        run_verification_runner(data)
      end)

    # Store task and trigger collection via state_timeout
    data = Map.put(data, :verification_task, verification_task)
    {:keep_state, data, {:state_timeout, 0, :collect_verification}}
  end

  def handle_event(:state_timeout, :collect_verification, :verifying, data) do
    runner_timeout = Map.get(data.config, :job_runner_timeout, 300_000)
    verification_task = Map.get(data, :verification_task)

    # Collect result directly in the Coordinator process (task owner)
    collect_verification_result(verification_task, runner_timeout, data)

    # Transition to :complete after verification
    {:next_state, :complete, data}
  end

  def handle_event(:enter, _old_state, :complete, data) do
    Logger.info("#{log_prefix(data)} Foreman entering :complete phase")
    broadcast_job_status(:complete, data)

    # Calculate job duration and get total cost
    duration_ms = System.monotonic_time(:millisecond) - data.job_start_time
    duration_sec = Float.round(duration_ms / 1000, 1)
    cost = RateLimiter.get_cumulative_cost(data.session_id)

    Logger.info("#{log_prefix(data)} Job complete (#{duration_sec}s, $#{Float.round(cost, 2)})")

    # Squash-merge all work, delete job branch, restore working state
    squash = Map.get(data.config, :job_squash_on_complete, true)

    case GitJob.complete_job(
           job_id: data.session_id,
           original_branch: data.original_branch,
           squash: squash,
           working_dir: data.working_dir
         ) do
      {:ok, :completed} ->
        Logger.info("#{log_prefix(data)} Successfully merged and cleaned up job branch")
        :keep_state_and_data

      {:error, reason} ->
        Logger.error("#{log_prefix(data)} Failed to complete job: #{inspect(reason)}")
        {:stop, {:shutdown, {:job_completion_failed, reason}}, data}
    end
  end

  # Set ForemanAgent PID
  def handle_event(:cast, {:set_foreman_agent, agent_name_or_pid}, state, data) do
    Logger.debug("#{log_prefix(data)} ForemanAgent set: #{inspect(agent_name_or_pid)}")

    # Demonitor the old ForemanAgent if it exists to prevent double-monitoring
    if data.foreman_agent_monitor_ref do
      Process.demonitor(data.foreman_agent_monitor_ref, [:flush])

      Logger.debug(
        "#{log_prefix(data)} Demonitored old ForemanAgent with ref: #{inspect(data.foreman_agent_monitor_ref)}"
      )
    end

    # Resolve to PID for monitoring, but keep the via-tuple/name for communication
    case resolve_agent_pid(agent_name_or_pid) do
      nil ->
        Logger.warning(
          "#{log_prefix(data)} Could not resolve ForemanAgent to PID: #{inspect(agent_name_or_pid)}"
        )

        {:keep_state, data}

      pid ->
        do_set_foreman_agent(pid, agent_name_or_pid, state, data)
    end
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
    Logger.info("#{log_prefix(data)} ForemanAgent ready to plan, transitioning to :planning")
    # Unsubscribe from ForemanAgent events when leaving :asking
    Registry.unregister(Deft.Registry, {:session, "#{data.session_id}-foreman"})
    {:next_state, :planning, data}
  end

  def handle_event(:info, {:agent_action, :research, topics}, :planning, data) do
    Logger.info(
      "#{log_prefix(data)} ForemanAgent requested research on topics: #{inspect(topics)}"
    )

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
      "#{log_prefix(data)} ForemanAgent submitted plan with #{length(deliverables)} deliverables (from :planning state)"
    )

    # Normalize deliverables and dependencies to use atom keys
    normalized_deliverables = Enum.map(deliverables, &normalize_deliverable_keys/1)
    normalized_dependencies = Enum.map(dependencies, &normalize_dependency_keys/1)

    # Validate the dependency DAG
    case validate_dag(normalized_deliverables, normalized_dependencies) do
      :ok ->
        # Store the full plan data
        full_plan = %{
          deliverables: normalized_deliverables,
          dependencies: normalized_dependencies,
          rationale: rationale
        }

        data = Map.put(data, :plan, full_plan)

        # Write plan to site log
        Store.write(site_log_name(data), "plan", full_plan)

        # Present plan to user for approval
        present_plan_to_user(data, normalized_deliverables)

        {:next_state, :decomposing, data}

      {:error, reason} ->
        Logger.warning("#{log_prefix(data)} Plan rejected due to invalid DAG: #{reason}")

        # Send rejection message to ForemanAgent and ask it to fix the plan
        rejection_prompt = """
        The submitted plan has an invalid dependency graph and was rejected.

        Error: #{reason}

        Please fix the dependency graph and submit a corrected plan. Ensure that:
        1. All :from and :to IDs in dependencies reference valid deliverable IDs
        2. No self-loops exist (where a deliverable depends on itself)
        3. No cycles exist in the dependency graph

        Original plan:
        - Deliverables: #{inspect(normalized_deliverables, pretty: true)}
        - Dependencies: #{inspect(normalized_dependencies, pretty: true)}
        """

        if data.foreman_agent_pid do
          Deft.Agent.prompt(data.foreman_agent_pid, rejection_prompt)
        end

        :keep_state_and_data
    end
  end

  def handle_event(:info, {:agent_action, :plan, plan_data}, :researching, data) do
    deliverables = Map.get(plan_data, :deliverables, [])
    dependencies = Map.get(plan_data, :dependencies, [])
    rationale = Map.get(plan_data, :rationale, "")

    Logger.info(
      "#{log_prefix(data)} ForemanAgent submitted plan with #{length(deliverables)} deliverables"
    )

    # Normalize deliverables and dependencies to use atom keys
    normalized_deliverables = Enum.map(deliverables, &normalize_deliverable_keys/1)
    normalized_dependencies = Enum.map(dependencies, &normalize_dependency_keys/1)

    # Validate the dependency DAG
    case validate_dag(normalized_deliverables, normalized_dependencies) do
      :ok ->
        # Store the full plan data
        full_plan = %{
          deliverables: normalized_deliverables,
          dependencies: normalized_dependencies,
          rationale: rationale
        }

        data = Map.put(data, :plan, full_plan)

        # Write plan to site log
        Store.write(site_log_name(data), "plan", full_plan)

        # Present plan to user for approval
        present_plan_to_user(data, normalized_deliverables)

        {:next_state, :decomposing, data}

      {:error, reason} ->
        Logger.warning("#{log_prefix(data)} Plan rejected due to invalid DAG: #{reason}")

        # Send rejection message to ForemanAgent and ask it to fix the plan
        rejection_prompt = """
        The submitted plan has an invalid dependency graph and was rejected.

        Error: #{reason}

        Please fix the dependency graph and submit a corrected plan. Ensure that:
        1. All :from and :to IDs in dependencies reference valid deliverable IDs
        2. No self-loops exist (where a deliverable depends on itself)
        3. No cycles exist in the dependency graph

        Original plan:
        - Deliverables: #{inspect(normalized_deliverables, pretty: true)}
        - Dependencies: #{inspect(normalized_dependencies, pretty: true)}
        """

        if data.foreman_agent_pid do
          Deft.Agent.prompt(data.foreman_agent_pid, rejection_prompt)
        end

        :keep_state_and_data
    end
  end

  def handle_event(:info, {:agent_action, :spawn_lead, deliverable_info}, :executing, data) do
    # Look up full deliverable from plan by ID
    deliverable_id = Map.get(deliverable_info, :id)
    additional_context = Map.get(deliverable_info, :context, "")

    # Cancel crash decision timer if this is a retry for a crashed Lead
    updated_data = cancel_crash_decision_timer_for_deliverable(data, deliverable_id)

    case find_deliverable_by_id(updated_data.plan, deliverable_id) do
      nil ->
        Logger.error(
          "#{log_prefix(data)} Cannot spawn Lead: deliverable '#{deliverable_id}' not found in plan"
        )

        :keep_state_and_data

      deliverable ->
        handle_spawn_lead_with_deliverable(
          deliverable,
          deliverable_id,
          additional_context,
          updated_data
        )
    end
  end

  def handle_event(:info, {:agent_action, :unblock_lead, lead_id, contract}, :executing, data) do
    Logger.info("#{log_prefix(data)} ForemanAgent unblocking Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("#{log_prefix(data)} Cannot unblock Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          # Send contract to Lead
          send(lead.pid, {:foreman_contract, contract})
          Logger.info("#{log_prefix(data)} Sent contract to Lead #{lead_id}")

          # Remove from blocked_leads if present
          data = Map.update!(data, :blocked_leads, &Map.delete(&1, lead_id))
          {:keep_state, data}
        else
          Logger.warning(
            "#{log_prefix(data)} Cannot unblock Lead #{lead_id}: Lead PID not available"
          )

          :keep_state_and_data
        end
    end
  end

  def handle_event(:info, {:agent_action, :steer_lead, lead_id, content}, :executing, data) do
    Logger.info("#{log_prefix(data)} ForemanAgent steering Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("#{log_prefix(data)} Cannot steer Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          # Send steering to Lead
          send(lead.pid, {:foreman_steering, content})
          Logger.info("#{log_prefix(data)} Sent steering to Lead #{lead_id}")
          :keep_state_and_data
        else
          Logger.warning(
            "#{log_prefix(data)} Cannot steer Lead #{lead_id}: Lead PID not available"
          )

          :keep_state_and_data
        end
    end
  end

  def handle_event(:info, {:agent_action, :abort_lead, lead_id}, :executing, data) do
    Logger.info("#{log_prefix(data)} ForemanAgent aborting Lead #{lead_id}")

    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning("#{log_prefix(data)} Cannot abort Lead #{lead_id}: Lead not found")
        :keep_state_and_data

      lead ->
        if lead.pid do
          do_abort_lead(lead_id, lead.pid, data)
        else
          Logger.warning(
            "#{log_prefix(data)} Cannot abort Lead #{lead_id}: Lead PID not available"
          )

          :keep_state_and_data
        end
    end
  end

  def handle_event(:info, {:agent_action, :fail_deliverable, lead_id}, :executing, data) do
    Logger.info(
      "#{log_prefix(data)} ForemanAgent marking deliverable for Lead #{lead_id} as failed"
    )

    # Extract deliverable_id — for crashed Leads, read from pending_crash_decisions
    # (the lead was already removed from data.leads by do_handle_lead_crash).
    # For non-crashed Leads, fall back to reading from data.leads.
    deliverable_id =
      get_in(data, [:pending_crash_decisions, lead_id, :deliverable_id]) ||
        get_in(data, [:leads, lead_id, :deliverable, :id])

    # Cancel crash decision timer if this was in response to a crash
    updated_data = cancel_crash_decision_timer(data, lead_id)

    # Clean up worktree and monitor if this was NOT called after a crash
    updated_data = cleanup_failed_lead(updated_data, lead_id)

    # Record deliverable as failed and move Lead from started_leads to failed_leads
    updated_data = remove_failed_lead_from_tracking(updated_data, lead_id, deliverable_id)

    # Check if all Leads are complete (including failed ones) and transition to :verifying
    if all_leads_complete?(updated_data) do
      Logger.info(
        "#{log_prefix(data)} All Leads complete (including failed), transitioning to :verifying"
      )

      {:next_state, :verifying, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  # Handle user prompts
  def handle_event(:cast, {:prompt, text}, :asking, data) do
    Logger.debug("#{log_prefix(data)} User answer received in asking phase: #{text}")

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
    Logger.debug("#{log_prefix(data)} User prompt received in #{state}: #{text}")

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
    Logger.debug("#{log_prefix(data)} User prompt received in #{state}: #{text}")

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
    Logger.info("#{log_prefix(data)} Plan approved, transitioning to :executing")

    # Save plan to persistence
    if data.plan do
      jobs_dir = Project.jobs_dir(data.working_dir)
      plan_path = Path.join([jobs_dir, data.session_id, "plan.json"])
      File.write!(plan_path, Jason.encode!(data.plan))
    end

    {:next_state, :executing, data}
  end

  def handle_event(:cast, :reject_plan, :decomposing, data) do
    Logger.info("#{log_prefix(data)} Plan rejected, returning to :planning")
    {:next_state, :planning, data}
  end

  # Abort
  def handle_event(:cast, :abort, _state, data) do
    Logger.info("#{log_prefix(data)} Job aborted")

    # Clean up git worktrees and branches
    keep_failed_branches = Map.get(data.config, :job_keep_failed_branches, false)

    case GitJob.abort_job(
           job_id: data.session_id,
           original_branch: Map.get(data, :original_branch),
           working_dir: data.working_dir,
           keep_failed_branches: keep_failed_branches
         ) do
      :ok ->
        Logger.debug("#{log_prefix(data)} Git cleanup completed")

      {:error, reason} ->
        Logger.error("#{log_prefix(data)} Git cleanup failed: #{inspect(reason)}")
    end

    {:stop, :normal, data}
  end

  # Handle Lead messages
  def handle_event(:info, {:lead_message, type, content, metadata}, state, data) do
    Logger.debug("#{log_prefix(data)} Lead message received: #{type}")

    # Auto-promote certain message types to site log
    promote_lead_message_to_site_log(type, content, metadata, data)

    # Handle contract auto-unblocking at code speed
    updated_data =
      if type == :contract and state == :executing do
        handle_contract_auto_unblocking(content, metadata, data)
      else
        data
      end

    # Handle file-overlap conflict detection at code speed
    updated_data =
      if type == :artifact and state == :executing do
        handle_artifact_conflict_detection(content, metadata, updated_data)
      else
        updated_data
      end

    # Route message to ForemanAgent based on state and priority
    updated_data = route_lead_message_to_agent(type, content, metadata, state, updated_data)

    # Handle Lead completion - remove from tracking and check for transition to verifying
    result = handle_lead_completion(type, metadata, state, updated_data)

    # Broadcast job status after handling Lead message
    broadcast_and_return(result, state)
  end

  # Handle flush timer for buffered Lead messages
  def handle_event(:info, :flush_lead_messages, state, data) do
    cond do
      # When ForemanAgent is restarting, leave buffer intact for catch-up prompt
      data.foreman_agent_restarting ->
        :keep_state_and_data

      # Buffer is non-empty and agent is available
      data.lead_message_buffer != [] and data.foreman_agent_pid ->
        # Build consolidated prompt from buffered messages
        consolidated_message =
          build_consolidated_lead_message(data.lead_message_buffer, state, data)

        Deft.Agent.prompt(data.foreman_agent_pid, consolidated_message)

        # Clear buffer, timer, and start time
        {:keep_state,
         %{data | lead_message_buffer: [], lead_message_timer: nil, buffer_start_time: nil}}

      # No messages to flush or no agent
      true ->
        {:keep_state, %{data | lead_message_timer: nil, buffer_start_time: nil}}
    end
  end

  # Handle Lead process DOWN messages
  def handle_event(:info, {:DOWN, ref, :process, pid, reason}, state, data) do
    cond do
      # Check if ForemanAgent crashed
      ref == data.foreman_agent_monitor_ref ->
        handle_foreman_agent_down(pid, reason, data)

      # Check if Store crashed
      ref == Map.get(data, :store_monitor_ref) ->
        handle_store_down(pid, reason, data)

      # Check if RateLimiter crashed
      ref == Map.get(data, :rate_limiter_monitor_ref) ->
        handle_rate_limiter_down(pid, reason, data)

      # Check if a Lead crashed
      match?({:ok, _lead_id}, find_lead_by_monitor(data.lead_monitors, ref)) ->
        {:ok, lead_id} = find_lead_by_monitor(data.lead_monitors, ref)
        handle_lead_down(lead_id, pid, reason, state, data)

      # Monitor might be for another process (e.g., Runner)
      true ->
        :keep_state_and_data
    end
  end

  # Handle periodic cost checkpoint from RateLimiter
  def handle_event(:info, {:rate_limiter, :cost, cost}, _state, data) do
    Logger.info("#{log_prefix(data)} Cost checkpoint: $#{Float.round(cost, 2)}")
    :keep_state_and_data
  end

  # Handle cost warning from RateLimiter
  def handle_event(:info, {:rate_limiter, :cost_warning, cost}, _state, data) do
    Logger.info(
      "#{log_prefix(data)} Cost warning: $#{Float.round(cost, 2)} (approaching cost ceiling)"
    )

    # Notify user about cost warning
    message = """
    ⚠️  Cost Warning: This job has reached $#{Float.round(cost, 2)} and is approaching the cost ceiling.
    """

    notify_user(data, :cost_warning, message)

    :keep_state_and_data
  end

  # Handle cost ceiling reached from RateLimiter
  def handle_event(:info, {:rate_limiter, :cost_ceiling_reached, cost}, _state, data) do
    Logger.warning(
      "#{log_prefix(data)} Cost ceiling reached: $#{Float.round(cost, 2)}, execution paused"
    )

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
  def handle_event(:cast, :approve_continued_spending, state, data) do
    Logger.info("#{log_prefix(data)} User approved continued spending, notifying RateLimiter")

    # Call RateLimiter to reset cost ceiling flag
    RateLimiter.approve_continued_spending(data.session_id)

    message = "✅ Continued spending approved. Execution resumed."
    notify_user(data, :spending_approved, message)

    # Reset flag and flush buffered Lead messages as a consolidated catch-up prompt
    updated_data = %{data | cost_ceiling_reached: false}

    updated_data =
      if updated_data.lead_message_buffer != [] and updated_data.foreman_agent_pid do
        Logger.info(
          "#{log_prefix(data)} Flushing #{length(updated_data.lead_message_buffer)} buffered Lead messages as catch-up prompt"
        )

        # Build consolidated catch-up prompt from buffered messages
        consolidated_message =
          build_consolidated_lead_message(updated_data.lead_message_buffer, state, updated_data)

        Deft.Agent.prompt(updated_data.foreman_agent_pid, consolidated_message)

        # Clear buffer, timer, and start time
        %{updated_data | lead_message_buffer: [], lead_message_timer: nil, buffer_start_time: nil}
      else
        updated_data
      end

    {:keep_state, updated_data}
  end

  # Handle crash decision timeout - auto-fail if ForemanAgent hasn't responded
  def handle_event(:info, {:lead_crash_timeout, lead_id}, :executing, data) do
    # Check if lead_id is still in pending_crash_decisions
    case Map.get(data.pending_crash_decisions, lead_id) do
      nil ->
        # ForemanAgent already responded (called fail_deliverable or spawn_lead), nothing to do
        Logger.debug(
          "#{log_prefix(data)} Crash timeout for Lead #{lead_id} fired but already handled, ignoring"
        )

        :keep_state_and_data

      crash_info ->
        auto_fail_crashed_deliverable(lead_id, crash_info, data)
    end
  end

  # Catch-all for unhandled events
  def handle_event(event_type, event_content, state, data) do
    Logger.warning(
      "#{log_prefix(data)} Unhandled event in #{state}: #{inspect(event_type)} #{inspect(event_content)}"
    )

    :keep_state_and_data
  end

  @impl :gen_statem
  def terminate(reason, state, data) do
    Logger.info("#{log_prefix(data)} Foreman terminating in #{state}: #{inspect(reason)}")
    cleanup(data)
    :ok
  end

  # Private functions

  defp do_set_foreman_agent(pid, agent_name_or_pid, state, data) do
    # Monitor the ForemanAgent so we can detect crashes
    monitor_ref = Process.monitor(pid)

    Logger.debug("#{log_prefix(data)} Monitoring ForemanAgent with ref: #{inspect(monitor_ref)}")

    # Keep the via-tuple in foreman_agent_pid for Deft.Agent.prompt/2 calls
    data =
      data
      |> Map.put(:foreman_agent_pid, agent_name_or_pid)
      |> Map.put(:foreman_agent_monitor_ref, monitor_ref)

    # If we're in :asking and didn't send the initial prompt yet, subscribe and send it now
    data = maybe_send_initial_prompt_on_set_agent(state, data, agent_name_or_pid)

    {:keep_state, data}
  end

  defp maybe_send_initial_prompt_on_set_agent(:asking, data, agent_name_or_pid)
       when not is_nil(data.prompt) do
    case Registry.register(Deft.Registry, {:session, "#{data.session_id}-foreman"}, []) do
      {:ok, _pid} ->
        Logger.debug("#{log_prefix(data)} Foreman subscribed to ForemanAgent events")

      {:error, {:already_registered, _pid}} ->
        Logger.debug("#{log_prefix(data)} Foreman already subscribed to ForemanAgent events")
    end

    Deft.Agent.prompt(agent_name_or_pid, data.prompt)
    data
  end

  defp maybe_send_initial_prompt_on_set_agent(_state, data, _agent_name_or_pid), do: data

  defp auto_fail_crashed_deliverable(lead_id, crash_info, data) do
    # ForemanAgent hasn't responded in time, auto-fail the deliverable
    Logger.warning(
      "#{log_prefix(data)} Lead #{lead_id} crash decision timeout - ForemanAgent did not respond, auto-failing deliverable"
    )

    # Extract deliverable_id from crash_info
    deliverable_id = Map.get(crash_info, :deliverable_id)

    # Remove from pending_crash_decisions
    updated_data =
      Map.update!(data, :pending_crash_decisions, &Map.delete(&1, lead_id))

    # Record deliverable as failed
    updated_data =
      Map.update!(updated_data, :deliverable_outcomes, &Map.put(&1, deliverable_id, :failed))

    # Apply same logic as fail_deliverable: move to failed_leads and remove from leads map
    updated_data =
      updated_data
      |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
      |> Map.update!(:failed_leads, &MapSet.put(&1, lead_id))
      |> Map.update!(:leads, &Map.delete(&1, lead_id))

    # Check if all Leads are complete (including failed ones) and transition to :verifying
    if all_leads_complete?(updated_data) do
      Logger.info(
        "#{log_prefix(data)} All Leads complete (including failed), transitioning to :verifying"
      )

      {:next_state, :verifying, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  defp relay_to_user(data, text) do
    Logger.info("#{log_prefix(data)} Foreman relaying ForemanAgent question to user")

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

  defp route_lead_message_to_agent(type, content, metadata, state, data) do
    if state == :executing and data.foreman_agent_pid do
      handle_lead_message_by_priority(type, content, metadata, state, data)
    else
      # Not in :executing state - log and discard
      if state != :executing do
        Logger.debug(
          "#{log_prefix(data)} Lead message discarded (not in :executing state): #{type}"
        )
      end

      data
    end
  end

  defp handle_lead_message_by_priority(type, content, metadata, state, data) do
    low_priority_types = [:status, :artifact, :decision, :finding, :contract, :contract_revision]
    high_priority_types = [:blocker, :complete, :error, :critical_finding]

    cond do
      type in low_priority_types ->
        buffer_low_priority_message(type, content, metadata, data)

      type in high_priority_types ->
        flush_lead_messages_immediately(type, content, metadata, state, data)

      true ->
        # Unknown type - treat as low priority
        Logger.warning(
          "#{log_prefix(data)} Unknown lead message type: #{type}, treating as low priority"
        )

        buffer_low_priority_message(type, content, metadata, data)
    end
  end

  defp buffer_low_priority_message(type, content, metadata, data) do
    buffer_entry = {type, content, metadata}
    debounce_ms = Map.get(data.config, :job_lead_message_debounce, 2_000)

    cond do
      # When cost ceiling is reached or ForemanAgent is restarting, buffer without setting timer
      data.cost_ceiling_reached or data.foreman_agent_restarting ->
        new_buffer = data.lead_message_buffer ++ [buffer_entry]
        %{data | lead_message_buffer: new_buffer}

      # Buffer is empty: start new buffer with this message and set timer
      data.lead_message_buffer == [] ->
        start_new_buffer(buffer_entry, debounce_ms, data)

      # Buffer is non-empty: check if max age reached
      true ->
        handle_buffered_message(buffer_entry, debounce_ms, data)
    end
  end

  defp start_new_buffer(buffer_entry, debounce_ms, data) do
    buffer_start_time = System.monotonic_time(:millisecond)
    timer_ref = Process.send_after(self(), :flush_lead_messages, debounce_ms)
    new_buffer = [buffer_entry]

    %{
      data
      | lead_message_buffer: new_buffer,
        lead_message_timer: timer_ref,
        buffer_start_time: buffer_start_time
    }
  end

  defp handle_buffered_message(buffer_entry, debounce_ms, data) do
    current_time = System.monotonic_time(:millisecond)
    age = current_time - data.buffer_start_time

    if age >= debounce_ms do
      flush_buffer_with_message(buffer_entry, data)
    else
      append_to_buffer(buffer_entry, data)
    end
  end

  defp flush_buffer_with_message(buffer_entry, data) do
    # Cancel timer if any
    _ =
      if data.lead_message_timer do
        Process.cancel_timer(data.lead_message_timer)
      end

    # Include the new message in the flush
    all_messages = data.lead_message_buffer ++ [buffer_entry]

    # If ForemanAgent is restarting, just buffer the message without sending
    if data.foreman_agent_restarting do
      %{data | lead_message_buffer: all_messages, lead_message_timer: nil, buffer_start_time: nil}
    else
      consolidated_message = build_consolidated_lead_message(all_messages, :running, data)
      Deft.Agent.prompt(data.foreman_agent_pid, consolidated_message)

      # Clear buffer, timer, and start time
      %{data | lead_message_buffer: [], lead_message_timer: nil, buffer_start_time: nil}
    end
  end

  defp append_to_buffer(buffer_entry, data) do
    new_buffer = data.lead_message_buffer ++ [buffer_entry]
    %{data | lead_message_buffer: new_buffer}
  end

  defp flush_lead_messages_immediately(
         high_priority_type,
         high_priority_content,
         high_priority_metadata,
         state,
         data
       ) do
    # Cancel existing timer if any
    _ =
      if data.lead_message_timer do
        Process.cancel_timer(data.lead_message_timer)
      end

    # Build consolidated message from buffer + current high-priority message
    all_messages =
      data.lead_message_buffer ++
        [{high_priority_type, high_priority_content, high_priority_metadata}]

    # If ForemanAgent is restarting, buffer even high-priority messages
    if data.foreman_agent_restarting do
      %{data | lead_message_buffer: all_messages, lead_message_timer: nil, buffer_start_time: nil}
    else
      consolidated_message = build_consolidated_lead_message(all_messages, state, data)

      # Send to ForemanAgent
      Deft.Agent.prompt(data.foreman_agent_pid, consolidated_message)

      # Clear buffer, timer, and start time
      %{data | lead_message_buffer: [], lead_message_timer: nil, buffer_start_time: nil}
    end
  end

  defp build_consolidated_lead_message(buffered_messages, state, data) do
    leads_status = format_leads_status(data.leads)
    contracts_info = format_contracts_from_sitelog(site_log_name(data))

    # Group messages by Lead
    grouped_by_lead =
      Enum.group_by(buffered_messages, fn {_type, _content, metadata} ->
        lead_id = Map.get(metadata, :lead_id, "unknown")
        lead_name = Map.get(metadata, :lead_name, "Unknown Lead")
        {lead_id, lead_name}
      end)

    # Format each Lead's messages
    lead_updates =
      Enum.map(grouped_by_lead, fn {{lead_id, lead_name}, messages} ->
        formatted_messages =
          Enum.map(messages, fn {type, content, _metadata} ->
            """
            **Type:** #{type}
            **Content:**
            #{inspect(content, pretty: true, limit: :infinity)}
            """
          end)
          |> Enum.join("\n\n---\n\n")

        """
        ### Updates from #{lead_name} (#{lead_id})

        #{formatted_messages}
        """
      end)
      |> Enum.join("\n\n")

    """
    ## Consolidated Lead Updates

    **Job Phase:** #{state}
    **Update Count:** #{length(buffered_messages)} message(s) since your last response

    #{lead_updates}

    ## Current Job State

    ### Active Leads

    #{leads_status}
    #{contracts_info}

    ### What to do

    Based on these updates, decide if you need to:
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

  defp format_contracts_from_sitelog(site_log_name) do
    tid = Store.tid(site_log_name)
    all_keys = Store.keys(tid)
    contract_keys = Enum.filter(all_keys, &String.starts_with?(&1, "contract-"))

    format_contract_list(tid, contract_keys)
  end

  defp extract_entry_content(%{value: %{content: c}}), do: c
  defp extract_entry_content(%{value: s}) when is_binary(s), do: s
  defp extract_entry_content(%{value: other}), do: inspect(other)

  defp format_contract_list(_tid, []), do: ""

  defp format_contract_list(tid, contract_keys) do
    formatted_contracts =
      Enum.map(contract_keys, fn key ->
        case Store.read(tid, key) do
          {:ok, entry} -> "- #{extract_entry_content(entry)}"
          _other -> "- [Could not read contract #{key}]"
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

  # Find a crashed lead in pending_crash_decisions that matches the given deliverable_id
  defp find_crashed_lead_for_deliverable(pending_crash_decisions, deliverable_id) do
    Enum.find(pending_crash_decisions, fn {_lead_id, crash_info} ->
      Map.get(crash_info, :deliverable_id) == deliverable_id
    end)
  end

  # Cancel crash decision timer for a specific lead_id (used by fail_deliverable)
  defp cancel_crash_decision_timer(data, lead_id) do
    case Map.get(data.pending_crash_decisions, lead_id) do
      nil ->
        data

      %{timer_ref: timer_ref} ->
        _ = Process.cancel_timer(timer_ref)
        Logger.debug("#{log_prefix(data)} Cancelled crash decision timer for Lead #{lead_id}")
        Map.update!(data, :pending_crash_decisions, &Map.delete(&1, lead_id))
    end
  end

  # Cancel crash decision timer for a deliverable_id (used by spawn_lead)
  defp cancel_crash_decision_timer_for_deliverable(data, deliverable_id) do
    case find_crashed_lead_for_deliverable(data.pending_crash_decisions, deliverable_id) do
      nil ->
        data

      {crashed_lead_id, %{timer_ref: timer_ref}} ->
        _ = Process.cancel_timer(timer_ref)

        Logger.debug(
          "#{log_prefix(data)} Cancelled crash decision timer for Lead #{crashed_lead_id} (retry with new Lead for deliverable #{deliverable_id})"
        )

        data
        |> Map.update!(:pending_crash_decisions, &Map.delete(&1, crashed_lead_id))
        |> Map.update!(:started_leads, &MapSet.delete(&1, crashed_lead_id))
        |> Map.update!(:failed_leads, &MapSet.put(&1, crashed_lead_id))
    end
  end

  # Match a published contract against the dependency DAG to find blocked leads to unblock
  defp match_contract_to_blocked_leads(metadata, data) do
    with publishing_lead_id <- Map.get(metadata, :lead_id),
         publishing_lead when not is_nil(publishing_lead) <-
           Map.get(data.leads, publishing_lead_id),
         publishing_deliverable_id <- Map.get(publishing_lead.deliverable, :id) do
      find_blocked_leads_for_deliverable(publishing_deliverable_id, data)
    else
      _ -> []
    end
  end

  defp find_blocked_leads_for_deliverable(publishing_deliverable_id, data) do
    downstream_deliverable_ids = get_downstream_deliverable_ids(publishing_deliverable_id, data)

    data.blocked_leads
    |> Enum.filter(fn {lead_id, _} ->
      lead_matches_downstream_deliverable?(lead_id, downstream_deliverable_ids, data)
    end)
    |> Enum.map(fn {lead_id, _} ->
      lead = Map.get(data.leads, lead_id)
      {lead_id, lead.pid}
    end)
  end

  defp get_downstream_deliverable_ids(publishing_deliverable_id, data) do
    dependencies = Map.get(data.plan || %{}, :dependencies, [])

    dependencies
    |> Enum.filter(fn dep -> Map.get(dep, :from) == publishing_deliverable_id end)
    |> Enum.map(fn dep -> Map.get(dep, :to) end)
  end

  defp lead_matches_downstream_deliverable?(lead_id, downstream_deliverable_ids, data) do
    case Map.get(data.leads, lead_id) do
      nil -> false
      lead -> Map.get(lead.deliverable, :id) in downstream_deliverable_ids
    end
  end

  # Handle contract auto-unblocking at code speed
  defp handle_contract_auto_unblocking(contract, metadata, data) do
    matches = match_contract_to_blocked_leads(metadata, data)

    if Enum.empty?(matches) do
      data
    else
      publishing_lead_id = Map.get(metadata, :lead_id)
      publishing_lead = Map.get(data.leads, publishing_lead_id)

      publishing_deliverable_name =
        Map.get(publishing_lead.deliverable, :name, publishing_lead_id)

      # Send contract to each blocked lead and update state
      Enum.reduce(matches, data, fn {blocked_lead_id, blocked_lead_pid}, acc_data ->
        # Send contract directly to the blocked lead
        send(blocked_lead_pid, {:foreman_contract, contract})

        blocked_lead = Map.get(acc_data.leads, blocked_lead_id)
        blocked_deliverable_name = Map.get(blocked_lead.deliverable, :name, blocked_lead_id)

        Logger.info(
          "#{log_prefix(acc_data)} Contract from #{publishing_deliverable_name} auto-forwarded to #{blocked_deliverable_name}"
        )

        # Update state: remove from blocked_leads, add to started_leads
        acc_data
        |> Map.update!(:blocked_leads, &Map.delete(&1, blocked_lead_id))
        |> Map.update!(:started_leads, &MapSet.put(&1, blocked_lead_id))
      end)
    end
  end

  # Handle file-overlap conflict detection at code speed
  defp handle_artifact_conflict_detection(content, metadata, data) do
    lead_id = Map.get(metadata, :lead_id)

    # Extract file paths from artifact content
    files = extract_file_paths(content)

    if MapSet.size(files) == 0 do
      # No files in this artifact
      data
    else
      # Update lead_modified_files for this lead
      updated_files_map =
        Map.update(
          data.lead_modified_files,
          lead_id,
          files,
          fn existing_files -> MapSet.union(existing_files, files) end
        )

      # Check for conflicts with other active leads
      conflicting_leads =
        updated_files_map
        |> Enum.filter(fn {other_lead_id, other_files} ->
          other_lead_id != lead_id and not MapSet.disjoint?(files, other_files)
        end)
        |> Enum.map(fn {other_lead_id, other_files} ->
          overlap = MapSet.intersection(files, other_files)
          {other_lead_id, overlap}
        end)

      data_with_updated_files = %{data | lead_modified_files: updated_files_map}

      if Enum.empty?(conflicting_leads) do
        # No conflicts
        data_with_updated_files
      else
        # Conflict detected - pause leads and notify ForemanAgent
        handle_file_overlap_conflict(lead_id, conflicting_leads, data_with_updated_files)
      end
    end
  end

  defp extract_file_paths(content) do
    # Extract lines that look like file paths
    # A file path typically contains / or starts with common patterns
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      String.contains?(line, "/") or String.match?(line, ~r/^[\w\-_]+\.\w+$/)
    end)
    |> MapSet.new()
  end

  defp handle_file_overlap_conflict(lead_id, conflicting_leads, data) do
    lead = Map.get(data.leads, lead_id)
    lead_name = Map.get(lead.deliverable, :name, lead_id)

    # Send pause steering to all affected leads
    send_pause_steering_to_leads(lead, lead_name, conflicting_leads, data)

    # Notify ForemanAgent of conflict
    notify_foreman_agent_of_conflict(lead_name, conflicting_leads, data)

    data
  end

  defp send_pause_steering_to_leads(lead, lead_name, conflicting_leads, data) do
    Enum.each(conflicting_leads, fn {other_lead_id, overlap_files} ->
      other_lead = Map.get(data.leads, other_lead_id)
      other_lead_name = Map.get(other_lead.deliverable, :name, other_lead_id)
      overlapping_files_list = MapSet.to_list(overlap_files) |> Enum.join(", ")

      send_pause_message_to_lead(lead, other_lead_name, overlapping_files_list)
      send_pause_message_to_lead(other_lead, lead_name, overlapping_files_list)

      Logger.warning(
        "#{log_prefix(data)} File conflict detected between #{lead_name} and #{other_lead_name} on files: #{overlapping_files_list}"
      )
    end)
  end

  defp send_pause_message_to_lead(lead, conflicting_lead_name, files_list) do
    if lead.pid do
      pause_message = """
      **FILE CONFLICT DETECTED**

      Your work overlaps with Lead #{conflicting_lead_name} on these files: #{files_list}

      Please wait for Foreman guidance before continuing work on these files.
      """

      send(lead.pid, {:foreman_steering, pause_message})
    end
  end

  defp notify_foreman_agent_of_conflict(lead_name, conflicting_leads, data) do
    if data.foreman_agent_pid and not data.foreman_agent_restarting do
      conflict_summary = build_conflict_summary(lead_name, conflicting_leads, data)

      conflict_prompt = """
      **FILE OVERLAP CONFLICT**

      Multiple Leads are modifying the same files:

      #{conflict_summary}

      Review the conflict and decide:
      - Use `steer_lead` to give specific guidance to one or both Leads
      - Use `abort_lead` if one should stop completely
      - Provide coordination strategy if both can proceed with caution
      """

      Deft.Agent.prompt(data.foreman_agent_pid, conflict_prompt)
    end
  end

  defp build_conflict_summary(lead_name, conflicting_leads, data) do
    conflicting_leads
    |> Enum.map(fn {other_lead_id, overlap_files} ->
      other_lead = Map.get(data.leads, other_lead_id)
      other_lead_name = Map.get(other_lead.deliverable, :name, other_lead_id)
      overlapping_files_list = MapSet.to_list(overlap_files) |> Enum.join(", ")
      "- #{lead_name} ↔ #{other_lead_name}: #{overlapping_files_list}"
    end)
    |> Enum.join("\n")
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

    Logger.info(
      "#{log_prefix(data)} ForemanAgent requested spawning Lead for: #{inspect(deliverable[:name])}"
    )

    # Check if Lead already started for this deliverable
    if deliverable_already_started?(data, deliverable_id) do
      Logger.warning(
        "#{log_prefix(data)} Lead for deliverable #{deliverable_id} already started, ignoring spawn request"
      )

      :keep_state_and_data
    else
      # Clear any previous outcome for this deliverable (e.g., from auto-fail after crash)
      # This prevents premature transition to :verifying when retrying a failed deliverable
      updated_data = Map.update!(data, :deliverable_outcomes, &Map.delete(&1, deliverable_id))

      # Generate unique Lead ID
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"

      case do_spawn_lead(lead_id, deliverable_with_context, updated_data) do
        {:ok, updated_data} ->
          # Broadcast updated status with new Lead
          broadcast_job_status(:executing, updated_data)
          {:keep_state, updated_data}

        # On spawn failure, still keep the cleared outcome so ForemanAgent can retry
        :error ->
          {:keep_state, updated_data}
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
         {:ok, {lead_supervisor_pid, lead_pid}} <-
           start_lead_process(lead_id, deliverable, worktree_path, data) do
      # Monitor the Lead gen_statem process
      monitor_ref = Process.monitor(lead_pid)

      # Track Lead with monitoring
      # Store lead_supervisor_pid (the DynamicSupervisor child) for termination
      updated_data =
        data
        |> Map.update!(:started_leads, &MapSet.put(&1, lead_id))
        |> put_in([:leads, lead_id], %{
          deliverable: deliverable,
          status: :running,
          pid: lead_pid,
          supervisor_pid: lead_supervisor_pid,
          worktree_path: worktree_path
        })
        |> put_in([:lead_monitors, lead_id], monitor_ref)

      Logger.info("#{log_prefix(data)} Lead spawned: #{lead_id}, task: #{deliverable[:name]}")

      {:ok, updated_data}
    else
      {:error, reason} ->
        Logger.error("#{log_prefix(data)} Failed to spawn Lead #{lead_id}: #{inspect(reason)}")
        :error
    end
  end

  defp create_lead_worktree(lead_id, data) do
    Logger.debug("#{log_prefix(data)} Creating worktree for Lead #{lead_id}")

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
      rate_limiter_pid: rate_limiter_name(data),
      worktree_path: worktree_path,
      working_dir: data.working_dir,
      runner_supervisor: runner_supervisor_name
    ]

    LeadSupervisor.start_lead(data.session_id, lead_opts)
  end

  defp do_abort_lead(lead_id, _lead_pid, data) do
    # Extract deliverable_id and supervisor_pid before removing from leads map
    deliverable_id = get_in(data, [:leads, lead_id, :deliverable, :id])
    supervisor_pid = get_in(data, [:leads, lead_id, :supervisor_pid])

    # Clean up monitor if present
    cleanup_lead_monitor(data.lead_monitors, lead_id)

    # Stop Lead supervisor subtree via DynamicSupervisor
    # This cascades shutdown to Lead, Lead, ToolRunner, and RunnerSupervisor
    terminate_lead_supervisor(lead_id, supervisor_pid, data)

    # Clean up the Lead's worktree AFTER termination
    cleanup_lead_worktree(lead_id, data)

    # Remove from tracking and mark as failed
    data = remove_aborted_lead_from_tracking(lead_id, deliverable_id, data)

    {:keep_state, data}
  end

  defp terminate_lead_supervisor(_lead_id, nil, _data), do: :ok

  defp terminate_lead_supervisor(lead_id, supervisor_pid, data) do
    lead_supervisor = LeadSupervisor.via_tuple(data.session_id)

    case DynamicSupervisor.terminate_child(lead_supervisor, supervisor_pid) do
      :ok ->
        Logger.info("#{log_prefix(data)} Terminated Lead #{lead_id} supervisor subtree")

      {:error, :not_found} ->
        Logger.warning(
          "#{log_prefix(data)} Lead #{lead_id} supervisor not found during termination"
        )
    end
  end

  defp cleanup_lead_worktree(lead_id, data) do
    Logger.debug("#{log_prefix(data)} Cleaning up worktree for aborted Lead #{lead_id}")

    GitJob.cleanup_lead_worktree(
      lead_id: lead_id,
      working_dir: data.working_dir
    )
  end

  defp remove_completed_lead_from_tracking(lead_id, deliverable_id, data) do
    data
    |> Map.update!(:deliverable_outcomes, &Map.put(&1, deliverable_id, :completed))
    |> Map.update!(:leads, &Map.delete(&1, lead_id))
    |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))
    |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
    |> Map.update!(:completed_leads, &MapSet.put(&1, lead_id))
    |> Map.update!(:lead_modified_files, &Map.delete(&1, lead_id))
  end

  defp remove_failed_lead_from_tracking(data, lead_id, deliverable_id) do
    data
    |> Map.update!(:deliverable_outcomes, &Map.put(&1, deliverable_id, :failed))
    |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
    |> Map.update!(:failed_leads, &MapSet.put(&1, lead_id))
    |> Map.update!(:leads, &Map.delete(&1, lead_id))
    |> Map.update!(:lead_modified_files, &Map.delete(&1, lead_id))
  end

  defp remove_aborted_lead_from_tracking(lead_id, deliverable_id, data) do
    data
    |> Map.update!(:deliverable_outcomes, &Map.put(&1, deliverable_id, :failed))
    |> Map.update!(:leads, &Map.delete(&1, lead_id))
    |> Map.update!(:started_leads, &MapSet.delete(&1, lead_id))
    |> Map.update!(:blocked_leads, &Map.delete(&1, lead_id))
    |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))
    |> Map.update!(:failed_leads, &MapSet.put(&1, lead_id))
    |> Map.update!(:lead_modified_files, &Map.delete(&1, lead_id))
  end

  # Clean up worktree and monitor for a failed Lead, but only if not already cleaned up
  # by do_handle_lead_crash (which removes the Lead from the map before calling fail_deliverable)
  defp cleanup_failed_lead(data, lead_id) do
    case Map.get(data.leads, lead_id) do
      nil ->
        # Lead already removed from map — cleanup already done by do_handle_lead_crash
        data

      lead_info ->
        # Lead still in map — this is a non-crash failure, terminate supervisor subtree,
        # clean up worktree and monitor
        Logger.debug(
          "#{log_prefix(data)} Cleaning up supervisor, worktree and monitor for failed Lead #{lead_id}"
        )

        # Stop Lead supervisor subtree via DynamicSupervisor
        # This cascades shutdown to Lead, Lead, ToolRunner, and RunnerSupervisor
        terminate_lead_supervisor(lead_id, lead_info.supervisor_pid, data)

        GitJob.cleanup_lead_worktree(
          lead_id: lead_id,
          working_dir: data.working_dir
        )

        cleanup_lead_monitor(data.lead_monitors, lead_id)

        data
        |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))
    end
  end

  defp cleanup_lead_monitor(monitors, lead_id) do
    case Map.get(monitors, lead_id) do
      nil -> :ok
      monitor_ref -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp all_leads_complete?(data) do
    # All Leads are complete when every deliverable in the plan has an outcome
    # (either :completed or :failed) in deliverable_outcomes.
    if data.plan && data.plan.deliverables do
      deliverables = data.plan.deliverables
      deliverable_ids = Enum.map(deliverables, fn d -> Map.get(d, :id) end)

      Enum.all?(deliverable_ids, fn deliverable_id ->
        Map.has_key?(data.deliverable_outcomes, deliverable_id)
      end)
    else
      # Fallback: if no plan exists yet, check if started_leads is empty
      MapSet.size(data.started_leads) == 0
    end
  end

  defp handle_correct_command(text, data) do
    # Parse /correct command and promote to site log if detected
    case String.trim(text) do
      "/correct " <> message when byte_size(message) > 0 ->
        Logger.info("#{log_prefix(data)} User correction detected: #{message}")
        metadata = %{source: :user}
        promote_lead_message_to_site_log(:correction, message, metadata, data)

      _ ->
        :ok
    end
  end

  defp promote_lead_message_to_site_log(type, content, metadata, data) do
    if type in [:contract, :decision, :correction, :critical_finding] do
      # Generate unique key with type prefix
      unique_id = :erlang.unique_integer([:positive])
      key = "#{type}-#{unique_id}"

      Store.write(
        site_log_name(data),
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

      # Guard against late completion messages for already-removed Leads
      if not Map.has_key?(data.leads, lead_id) do
        Logger.warning(
          "#{log_prefix(data)} Ignoring late completion for lead_id #{lead_id} — already removed from tracking"
        )

        {:keep_state, data}
      else
        process_lead_completion(lead_id, state, data)
      end
    else
      # Pass through the data to preserve buffer and other state updates
      {:keep_state, data}
    end
  end

  defp process_lead_completion(lead_id, state, data) do
    deliverable_name = get_in(data, [:leads, lead_id, :deliverable, :name])
    deliverable_id = get_in(data, [:leads, lead_id, :deliverable, :id])
    Logger.info("#{log_prefix(data)} Lead completed: #{lead_id}, task: #{deliverable_name}")

    # Attempt to merge the Lead's branch into the job branch
    Logger.debug("#{log_prefix(data)} Merging Lead branch for #{lead_id} into job branch")

    merge_result =
      GitJob.merge_lead_branch(
        lead_id: lead_id,
        job_id: data.session_id,
        working_dir: data.working_dir
      )

    updated_data =
      case merge_result do
        {:ok, :merged} ->
          Logger.info("#{log_prefix(data)} Lead #{lead_id} merged successfully")

          # Clean up the Lead's worktree after successful merge
          GitJob.cleanup_lead_worktree(
            lead_id: lead_id,
            working_dir: data.working_dir
          )

          # Demonitor the Lead and remove from tracking
          cleanup_lead_monitor(data.lead_monitors, lead_id)
          remove_completed_lead_from_tracking(lead_id, deliverable_id, data)

        {:ok, :conflict, conflicted_files, temp_dir} ->
          Logger.warning(
            "#{log_prefix(data)} Merge conflict detected for Lead #{lead_id}. Conflicted files: #{inspect(conflicted_files)}"
          )

          # Spawn a merge_resolution Runner to resolve the conflict
          updated_data = spawn_merge_resolution_runner(lead_id, conflicted_files, temp_dir, data)

          # Demonitor the Lead and remove from tracking (Runner will handle the merge)
          cleanup_lead_monitor(data.lead_monitors, lead_id)
          remove_completed_lead_from_tracking(lead_id, deliverable_id, updated_data)

        {:error, reason} ->
          Logger.error("#{log_prefix(data)} Failed to merge Lead #{lead_id}: #{inspect(reason)}")

          # Clean up worktree on merge error
          GitJob.cleanup_lead_worktree(
            lead_id: lead_id,
            working_dir: data.working_dir
          )

          # Demonitor the Lead and remove from tracking
          cleanup_lead_monitor(data.lead_monitors, lead_id)
          remove_completed_lead_from_tracking(lead_id, deliverable_id, data)
      end

    # Check if all Leads are complete and transition to :verifying
    if state == :executing and all_leads_complete?(updated_data) do
      Logger.info("#{log_prefix(data)} All Leads complete, transitioning to :verifying")
      {:next_state, :verifying, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  # Check if an exit reason is normal (not a crash)
  defp normal_exit?(reason) when reason in [:normal, :shutdown], do: true
  defp normal_exit?({:shutdown, _}), do: true
  defp normal_exit?(_reason), do: false

  # Handle ForemanAgent DOWN message
  defp handle_foreman_agent_down(pid, reason, data) do
    if normal_exit?(reason) do
      Logger.info(
        "#{log_prefix(data)} ForemanAgent (#{inspect(pid)}) exited normally: #{inspect(reason)}"
      )

      :keep_state_and_data
    else
      restart_count = Map.get(data, :foreman_agent_restart_count, 0)

      if restart_count == 0 do
        Logger.warning(
          "#{log_prefix(data)} ForemanAgent (#{inspect(pid)}) crashed: #{inspect(reason)}. Attempting restart (first crash)."
        )

        do_restart_foreman_agent(reason, data)
      else
        Logger.error(
          "#{log_prefix(data)} ForemanAgent (#{inspect(pid)}) crashed: #{inspect(reason)}. Second crash after restart - failing job with cleanup."
        )

        do_fail_job_on_foreman_agent_crash(reason, data)
      end
    end
  end

  # Handle Store DOWN message
  defp handle_store_down(pid, reason, data) do
    Logger.error(
      "#{log_prefix(data)} Store (#{inspect(pid)}) crashed: #{inspect(reason)}. Failing job with cleanup."
    )

    do_fail_job_on_infrastructure_crash(:store, reason, data)
  end

  # Handle RateLimiter DOWN message
  defp handle_rate_limiter_down(pid, reason, data) do
    Logger.error(
      "#{log_prefix(data)} RateLimiter (#{inspect(pid)}) crashed: #{inspect(reason)}. Failing job with cleanup."
    )

    do_fail_job_on_infrastructure_crash(:rate_limiter, reason, data)
  end

  # Handle Lead DOWN message
  defp handle_lead_down(lead_id, pid, reason, state, data) do
    if normal_exit?(reason) do
      Logger.info(
        "#{log_prefix(data)} Lead #{lead_id} (#{inspect(pid)}) exited normally: #{inspect(reason)}"
      )

      :keep_state_and_data
    else
      Logger.warning(
        "#{log_prefix(data)} Lead #{lead_id} (#{inspect(pid)}) crashed: #{inspect(reason)}"
      )

      do_handle_lead_crash(lead_id, state, data)
    end
  end

  defp do_fail_job_on_foreman_agent_crash(reason, data) do
    # ForemanAgent has crashed - fail the entire job with full cleanup
    Logger.error("#{log_prefix(data)} Failing job due to ForemanAgent crash: #{inspect(reason)}")

    # Demonitor all Leads to prevent spurious DOWN messages during shutdown
    Enum.each(data.lead_monitors, fn {_lead_id, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    # Demonitor ForemanAgent
    if data.foreman_agent_monitor_ref do
      Process.demonitor(data.foreman_agent_monitor_ref, [:flush])
    end

    # Clear the restarting flag
    data = %{data | foreman_agent_restarting: false}

    # Stop the Foreman - terminate/3 will call cleanup(data) to handle all cleanup
    {:stop, {:foreman_agent_crashed, reason}, data}
  end

  defp do_restart_foreman_agent(_reason, data) do
    # Demonitor the crashed ForemanAgent
    if data.foreman_agent_monitor_ref do
      Process.demonitor(data.foreman_agent_monitor_ref, [:flush])
    end

    # Set flag to indicate we're in the restart window
    data = %{data | foreman_agent_restarting: true}

    # Load session messages
    messages = load_foreman_session_messages(data)

    # Build ForemanAgent configuration
    foreman_agent_name = build_foreman_agent_name(data)
    agent_opts = build_foreman_agent_opts(data, messages, foreman_agent_name)

    # Start new Foreman agent and handle result
    case Foreman.start_link(agent_opts) do
      {:ok, _agent_pid} ->
        handle_foreman_agent_restart_success(foreman_agent_name, data)

      {:error, start_error} ->
        Logger.error(
          "#{log_prefix(data)} ForemanAgent restart failed: #{inspect(start_error)}. Failing job."
        )

        # Clear the restarting flag before failing
        data = %{data | foreman_agent_restarting: false}
        do_fail_job_on_foreman_agent_crash({:restart_failed, start_error}, data)
    end
  end

  defp load_foreman_session_messages(data) do
    session_path = SessionStore.foreman_session_path(data.session_id, data.working_dir)

    case File.read(session_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_session_entry/1)
        |> Enum.reject(&is_nil/1)
        |> extract_messages_from_entries()

      {:error, file_error} ->
        Logger.warning(
          "#{log_prefix(data)} Could not load ForemanAgent session JSONL: #{inspect(file_error)}. Starting with empty messages."
        )

        []
    end
  end

  defp build_foreman_agent_name(data) do
    {:via, Registry, {Deft.ProcessRegistry, {:foreman_agent, data.session_id}}}
  end

  defp build_foreman_agent_opts(data, messages, foreman_agent_name) do
    foreman_agent_session_id = "#{data.session_id}-foreman"
    rate_limiter_name = rate_limiter_name(data)
    foreman_name = {:via, Registry, {Deft.ProcessRegistry, {:foreman, data.session_id}}}

    [
      session_id: foreman_agent_session_id,
      config: data.config,
      parent_pid: foreman_name,
      rate_limiter: rate_limiter_name,
      working_dir: data.working_dir,
      messages: messages,
      name: foreman_agent_name
    ]
  end

  defp handle_foreman_agent_restart_success(foreman_agent_name, data) do
    pid = resolve_agent_pid(foreman_agent_name)

    if pid do
      monitor_ref = Process.monitor(pid)

      Logger.info(
        "#{log_prefix(data)} ForemanAgent restarted successfully. Monitoring with ref: #{inspect(monitor_ref)}"
      )

      # Update data with new monitor ref and increment restart count
      updated_data =
        data
        |> Map.put(:foreman_agent_monitor_ref, monitor_ref)
        |> Map.put(:foreman_agent_pid, foreman_agent_name)
        |> Map.update!(:foreman_agent_restart_count, &(&1 + 1))

      # Send catch-up prompt with current job state and buffered messages
      send_restart_catchup_prompt(updated_data)

      # Clear the restarting flag and buffer after sending catch-up
      updated_data = %{
        updated_data
        | foreman_agent_restarting: false,
          lead_message_buffer: [],
          lead_message_timer: nil,
          buffer_start_time: nil
      }

      {:keep_state, updated_data}
    else
      Logger.error(
        "#{log_prefix(data)} ForemanAgent restart failed: could not resolve agent PID. Failing job."
      )

      # Clear the restarting flag before failing
      data = %{data | foreman_agent_restarting: false}
      do_fail_job_on_foreman_agent_crash({:restart_failed, :pid_resolution}, data)
    end
  end

  defp do_fail_job_on_infrastructure_crash(component, reason, data) do
    # Store or RateLimiter has crashed - unrecoverable infrastructure failure
    Logger.error("#{log_prefix(data)} Failing job due to #{component} crash: #{inspect(reason)}")

    # Demonitor all processes to prevent spurious DOWN messages during shutdown
    Enum.each(data.lead_monitors, fn {_lead_id, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    if data.foreman_agent_monitor_ref do
      Process.demonitor(data.foreman_agent_monitor_ref, [:flush])
    end

    if Map.get(data, :store_monitor_ref) do
      Process.demonitor(data.store_monitor_ref, [:flush])
    end

    if Map.get(data, :rate_limiter_monitor_ref) do
      Process.demonitor(data.rate_limiter_monitor_ref, [:flush])
    end

    # Stop the Foreman - terminate/3 will call cleanup(data) to handle all cleanup
    {:stop, {component, :infrastructure_crash, reason}, data}
  end

  defp do_handle_lead_crash(lead_id, _state, data) do
    # Extract deliverable_id and supervisor_pid before removing the lead
    deliverable_id = extract_deliverable_id(data.leads, lead_id)
    supervisor_pid = get_in(data, [:leads, lead_id, :supervisor_pid])

    # Clean up monitor
    cleanup_lead_monitor(data.lead_monitors, lead_id)

    # Stop Lead supervisor subtree — cascades shutdown to Lead, ToolRunner, RunnerSupervisor.
    # This must happen BEFORE worktree cleanup to stop Runners that may still be writing.
    terminate_lead_supervisor(lead_id, supervisor_pid, data)

    # Clean up the crashed Lead's worktree after supervisor is stopped
    Logger.debug("#{log_prefix(data)} Cleaning up worktree for crashed Lead #{lead_id}")
    GitJob.cleanup_lead_worktree(lead_id: lead_id, working_dir: data.working_dir)
    Logger.info("#{log_prefix(data)} Cleaned up worktree for crashed Lead #{lead_id}")

    # Remove from tracking
    updated_data =
      data
      |> Map.update!(:leads, &Map.delete(&1, lead_id))
      |> Map.update!(:blocked_leads, &Map.delete(&1, lead_id))
      |> Map.update!(:lead_monitors, &Map.delete(&1, lead_id))
      |> Map.update!(:lead_modified_files, &Map.delete(&1, lead_id))

    # Notify agent and start crash decision timeout
    updated_data = setup_crash_decision_timeout(updated_data, lead_id, deliverable_id)

    {:keep_state, updated_data}
  end

  # Extract deliverable_id from a lead, handling various data shapes
  defp extract_deliverable_id(leads, lead_id) do
    case Map.get(leads, lead_id) do
      nil -> nil
      %{deliverable: deliverable} when is_map(deliverable) -> Map.get(deliverable, :id)
      _ -> nil
    end
  end

  # Notify ForemanAgent of crash and start decision timeout
  defp setup_crash_decision_timeout(data, lead_id, deliverable_id) do
    crash_notification = """
    Lead '#{lead_id}' has crashed and its worktree has been cleaned up.

    You must decide how to handle this:
    - Call `fail_deliverable` with lead_id='#{lead_id}' to mark this deliverable as failed and move forward
    - OR call `spawn_lead` to retry with a fresh Lead for this deliverable

    Consider the nature of the crash and whether a retry is likely to succeed.
    """

    # Only send notification if ForemanAgent is not restarting
    # When restarting, buffer the notification to include in post-restart catch-up
    if data.foreman_agent_pid && !data.foreman_agent_restarting do
      Deft.Agent.prompt(data.foreman_agent_pid, crash_notification)
    end

    timeout_ms = Map.get(data.config, :job_lead_crash_decision_timeout, 60_000)
    timer_ref = Process.send_after(self(), {:lead_crash_timeout, lead_id}, timeout_ms)

    Logger.debug(
      "#{log_prefix(data)} Started crash decision timeout for Lead #{lead_id} (#{timeout_ms}ms)"
    )

    Map.update!(data, :pending_crash_decisions, fn pending ->
      Map.put(pending, lead_id, %{
        timer_ref: timer_ref,
        deliverable_id: deliverable_id,
        notification: crash_notification
      })
    end)
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

  defp run_verification_runner(data) do
    runner_model = Map.get(data.config, :job_runner_model, "claude-sonnet-4")

    runner_config = %{
      model: runner_model,
      provider: Deft.Provider.Anthropic,
      temperature: 0.7
    }

    instructions = """
    Run verification checks on the completed work:

    1. Run the test suite to ensure all tests pass
    2. Check for any linting or formatting errors
    3. Review the changes for correctness and completeness

    Report any issues found or confirm that verification passed.
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

    case Runner.run(:verification, instructions, context, opts) do
      {:ok, output} ->
        %{status: :success, report: output}

      {:error, reason} ->
        %{status: :error, error: reason}
    end
  end

  defp spawn_merge_resolution_runner(lead_id, conflicted_files, temp_dir, data) do
    runner_model = Map.get(data.config, :job_runner_model, "claude-sonnet-4")

    runner_config = %{
      model: runner_model,
      provider: Deft.Provider.Anthropic,
      temperature: 0.7
    }

    instructions = """
    Resolve the merge conflict that occurred when merging Lead branch into the job branch.

    Conflicted files: #{inspect(conflicted_files)}

    Steps:
    1. Read the conflicted files to understand both sides of the conflict
    2. Resolve the conflicts by choosing the appropriate changes
    3. Stage the resolved files using git add
    4. Complete the merge using git commit

    Report the resolution approach and confirm when complete.
    """

    context = """
    Working directory (merge worktree): #{temp_dir}
    Job: #{data.session_id}
    Lead: #{lead_id}
    """

    opts = %{
      job_id: data.session_id,
      config: runner_config,
      worktree_path: temp_dir
    }

    # Spawn the merge resolution Runner async
    task =
      Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
        case Runner.run(:merge_resolution, instructions, context, opts) do
          {:ok, output} ->
            Logger.info("Merge resolution complete for Lead #{lead_id}")
            {:ok, lead_id, output}

          {:error, reason} ->
            Logger.error("Merge resolution failed for Lead #{lead_id}: #{inspect(reason)}")
            {:error, lead_id, reason}
        end
      end)

    Logger.info("#{log_prefix(data)} Spawned merge_resolution Runner for Lead #{lead_id}")

    # Track the task in merge_resolution_tasks map
    merge_resolution_tasks = Map.get(data, :merge_resolution_tasks, %{})
    updated_tasks = Map.put(merge_resolution_tasks, lead_id, %{task: task, temp_dir: temp_dir})

    Map.put(data, :merge_resolution_tasks, updated_tasks)
  end

  defp collect_verification_result(task, timeout, data) do
    result =
      case Task.yield(task, timeout) do
        {:ok, %{status: :success, report: report}} ->
          Logger.info("#{log_prefix(data)} Verification passed")
          "Verification complete. Results:\n\n#{report}"

        {:ok, %{status: :error, error: error}} ->
          Logger.warning("#{log_prefix(data)} Verification failed: #{error}")
          "Verification failed with error:\n\n#{error}"

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          Logger.warning("#{log_prefix(data)} Verification task timed out")
          "Verification task exceeded time limit (#{timeout}ms)"

        {:exit, reason} ->
          Logger.error("#{log_prefix(data)} Verification task crashed: #{inspect(reason)}")
          "Verification task crashed: #{inspect(reason)}"
      end

    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, result)
    end
  end

  defp collect_research_results(tasks, timeout, data) do
    results =
      tasks
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, res} ->
        case res do
          {:ok, result} ->
            result

          nil ->
            # Task didn't finish in time, shut it down
            _ = Task.shutdown(task, :brutal_kill)
            %{topic: "unknown", status: :timeout, error: "Research task timed out"}

          {:exit, reason} ->
            %{topic: "unknown", status: :error, error: inspect(reason)}
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
      Logger.warning("#{log_prefix(data)} ForemanAgent not available to receive research results")
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

    Logger.info("#{log_prefix(data)} Presenting plan to user:\n#{plan_summary}")

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

  # Validate the dependency DAG for a plan
  # Returns :ok or {:error, reason}
  defp validate_dag(deliverables, dependencies) do
    deliverable_ids = MapSet.new(deliverables, & &1[:id])

    with :ok <- validate_dependency_references(dependencies, deliverable_ids),
         :ok <- validate_no_self_loops(dependencies),
         :ok <- validate_no_cycles(dependencies) do
      :ok
    end
  end

  # Check that all :from and :to IDs in dependencies reference valid deliverable IDs
  defp validate_dependency_references(dependencies, deliverable_ids) do
    invalid_deps =
      Enum.filter(dependencies, fn dep ->
        from_id = dep[:from]
        to_id = dep[:to]
        not MapSet.member?(deliverable_ids, from_id) or not MapSet.member?(deliverable_ids, to_id)
      end)

    if Enum.empty?(invalid_deps) do
      :ok
    else
      invalid_ids =
        Enum.flat_map(invalid_deps, fn dep ->
          [dep[:from], dep[:to]]
        end)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(deliverable_ids, &1))

      {:error, "Invalid deliverable IDs in dependencies: #{inspect(invalid_ids)}"}
    end
  end

  # Check for self-loops (where from == to)
  defp validate_no_self_loops(dependencies) do
    self_loops = Enum.filter(dependencies, fn dep -> dep[:from] == dep[:to] end)

    if Enum.empty?(self_loops) do
      :ok
    else
      loop_ids = Enum.map(self_loops, & &1[:from])
      {:error, "Self-loops detected in dependencies: #{inspect(loop_ids)}"}
    end
  end

  # Check for cycles using topological sort (Kahn's algorithm)
  defp validate_no_cycles(dependencies) do
    # Build adjacency list and in-degree map
    {graph, in_degree} = build_graph(dependencies)

    # Find all nodes with in-degree 0
    queue = Enum.filter(Map.keys(graph), fn node -> Map.get(in_degree, node, 0) == 0 end)

    # Perform topological sort
    case topological_sort(queue, graph, in_degree, []) do
      {:ok, _sorted} ->
        :ok

      {:error, remaining} ->
        {:error, "Cycle detected in dependency graph involving: #{inspect(remaining)}"}
    end
  end

  # Build adjacency list and in-degree map from dependencies
  defp build_graph(dependencies) do
    # Initialize graph with all nodes
    all_nodes =
      Enum.flat_map(dependencies, fn dep -> [dep[:from], dep[:to]] end)
      |> Enum.uniq()

    initial_graph = Map.new(all_nodes, fn node -> {node, []} end)
    initial_in_degree = Map.new(all_nodes, fn node -> {node, 0} end)

    # Build adjacency list and count in-degrees
    Enum.reduce(dependencies, {initial_graph, initial_in_degree}, fn dep, {graph, in_degree} ->
      from = dep[:from]
      to = dep[:to]

      graph = Map.update!(graph, from, fn neighbors -> [to | neighbors] end)
      in_degree = Map.update!(in_degree, to, &(&1 + 1))

      {graph, in_degree}
    end)
  end

  # Kahn's algorithm for topological sort
  # Returns {:ok, sorted_list} or {:error, remaining_nodes_with_cycles}
  defp topological_sort([], graph, in_degree, sorted) do
    # Check if all nodes were processed
    remaining = Enum.filter(Map.keys(graph), fn node -> Map.get(in_degree, node, 0) > 0 end)

    if Enum.empty?(remaining) do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, remaining}
    end
  end

  defp topological_sort([node | rest], graph, in_degree, sorted) do
    # Get neighbors of current node
    neighbors = Map.get(graph, node, [])

    # Decrease in-degree of neighbors and add to queue if in-degree becomes 0
    {new_queue, new_in_degree} =
      Enum.reduce(neighbors, {rest, in_degree}, fn neighbor, {queue, degrees} ->
        new_degree = Map.get(degrees, neighbor) - 1
        degrees = Map.put(degrees, neighbor, new_degree)

        if new_degree == 0 do
          {[neighbor | queue], degrees}
        else
          {queue, degrees}
        end
      end)

    topological_sort(new_queue, graph, new_in_degree, [node | sorted])
  end

  defp cleanup(data) do
    # 1. Demonitor all processes (Leads with :flush, ForemanAgent)
    cleanup_demonitor_all(data)

    # 2. Stop each Lead's supervisor subtree via DynamicSupervisor
    cleanup_terminate_lead_supervisors(data)

    # 3. Clean up all Lead worktrees
    cleanup_all_lead_worktrees(data)

    # 4. Stop site log
    cleanup_site_log(data)

    :ok
  end

  defp cleanup_demonitor_all(data) do
    try do
      Enum.each(data.lead_monitors, fn {_lead_id, monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
      end)

      if data.foreman_agent_monitor_ref do
        Process.demonitor(data.foreman_agent_monitor_ref, [:flush])
      end

      if Map.get(data, :store_monitor_ref) do
        Process.demonitor(data.store_monitor_ref, [:flush])
      end

      if Map.get(data, :rate_limiter_monitor_ref) do
        Process.demonitor(data.rate_limiter_monitor_ref, [:flush])
      end
    rescue
      error ->
        Logger.warning("#{log_prefix(data)} Error demonitoring processes: #{inspect(error)}")
    end
  end

  defp cleanup_terminate_lead_supervisors(data) do
    try do
      lead_supervisor = LeadSupervisor.via_tuple(data.session_id)

      Enum.each(data.leads, fn {lead_id, lead} ->
        supervisor_pid = Map.get(lead, :supervisor_pid)

        if supervisor_pid do
          case DynamicSupervisor.terminate_child(lead_supervisor, supervisor_pid) do
            :ok ->
              Logger.debug("#{log_prefix(data)} Stopped Lead #{lead_id} during cleanup")

            {:error, :not_found} ->
              Logger.debug(
                "#{log_prefix(data)} Lead #{lead_id} supervisor not found during cleanup"
              )
          end
        end
      end)
    rescue
      error ->
        Logger.warning("#{log_prefix(data)} Error stopping Lead supervisors: #{inspect(error)}")
    end
  end

  defp cleanup_all_lead_worktrees(data) do
    try do
      Enum.each(data.leads, fn {lead_id, _lead} ->
        Logger.debug("#{log_prefix(data)} Cleaning up worktree for Lead #{lead_id}")

        GitJob.cleanup_lead_worktree(
          lead_id: lead_id,
          working_dir: data.working_dir
        )
      end)
    rescue
      error ->
        Logger.warning("#{log_prefix(data)} Error cleaning up Lead worktrees: #{inspect(error)}")
    end
  end

  defp cleanup_site_log(data) do
    try do
      Store.cleanup(site_log_name(data))
    rescue
      ArgumentError -> :ok
    catch
      # Store may already be dead if it crashed
      :exit, {:noproc, _} -> :ok
    end
  end

  # Parse a JSONL line into a session entry
  defp parse_session_entry(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, data} -> deserialize_session_entry(data)
      {:error, _reason} -> nil
    end
  end

  # Deserialize JSON data into message entry (only Message type for ForemanAgent)
  defp deserialize_session_entry(%{type: type} = data)
       when type in ["message", :message] do
    %{
      type: :message,
      message_id: data.message_id,
      role: parse_role(data.role),
      content: data.content,
      timestamp: parse_datetime_for_entry(data.timestamp)
    }
  end

  defp deserialize_session_entry(_unknown), do: nil

  defp parse_role(role) when role in [:user, :assistant, :system], do: role
  defp parse_role(role) when is_binary(role), do: String.to_existing_atom(role)
  defp parse_role(_), do: :user

  defp parse_datetime_for_entry(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_datetime_for_entry(%DateTime{} = dt), do: dt
  defp parse_datetime_for_entry(_), do: DateTime.utc_now()

  # Extract messages from session entries
  defp extract_messages_from_entries(entries) do
    entries
    |> Enum.filter(&match?(%{type: :message}, &1))
    |> Enum.map(&entry_to_deft_message/1)
  end

  # Convert entry to Deft.Message
  defp entry_to_deft_message(entry) do
    %Deft.Message{
      id: entry.message_id,
      role: entry.role,
      content: deserialize_message_content(entry.content),
      timestamp: entry.timestamp
    }
  end

  defp deserialize_message_content(content) when is_list(content) do
    content
    |> Enum.map(&deserialize_content_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp deserialize_message_content(_), do: []

  defp deserialize_content_block(%{type: "text"} = block) do
    %Deft.Message.Text{text: block[:text] || ""}
  end

  defp deserialize_content_block(%{type: :text} = block) do
    %Deft.Message.Text{text: block[:text] || ""}
  end

  defp deserialize_content_block(%{type: "tool_use"} = block) do
    %Deft.Message.ToolUse{
      id: block[:id] || "",
      name: block[:name] || "",
      args: block[:input] || block[:args] || %{}
    }
  end

  defp deserialize_content_block(%{type: :tool_use} = block) do
    %Deft.Message.ToolUse{
      id: block[:id] || "",
      name: block[:name] || "",
      args: block[:input] || block[:args] || %{}
    }
  end

  defp deserialize_content_block(%{type: "tool_result"} = block) do
    %Deft.Message.ToolResult{
      tool_use_id: block[:tool_use_id] || "",
      name: block[:name],
      content: block[:content] || "",
      is_error: block[:is_error] || false
    }
  end

  defp deserialize_content_block(%{type: :tool_result} = block) do
    %Deft.Message.ToolResult{
      tool_use_id: block[:tool_use_id] || "",
      name: block[:name],
      content: block[:content] || "",
      is_error: block[:is_error] || false
    }
  end

  defp deserialize_content_block(_unknown), do: nil

  # Send catch-up prompt to restarted ForemanAgent
  defp send_restart_catchup_prompt(data) do
    # Build current job state summary
    active_leads_summary =
      data.leads
      |> Enum.map(fn {lead_id, lead} ->
        "- #{lead_id}: deliverable '#{lead.deliverable.id}' (#{lead.deliverable.description})"
      end)
      |> Enum.join("\n")

    deliverable_outcomes_summary =
      data.deliverable_outcomes
      |> Enum.map(fn {deliverable_id, outcome} ->
        "- #{deliverable_id}: #{outcome}"
      end)
      |> Enum.join("\n")

    # Build buffered messages section if there are any
    buffered_messages_section =
      if data.lead_message_buffer != [] do
        Logger.info(
          "#{log_prefix(data)} Flushing #{length(data.lead_message_buffer)} buffered Lead messages in restart catch-up prompt"
        )

        # Build consolidated lead message from buffer
        consolidated_lead_updates =
          build_consolidated_lead_message(data.lead_message_buffer, :executing, data)

        """

        **Buffered Lead messages during restart:**

        #{consolidated_lead_updates}
        """
      else
        ""
      end

    # Build pending crash notifications section if there are any
    crash_notifications_section =
      if data.pending_crash_decisions != %{} do
        crash_notifications =
          data.pending_crash_decisions
          |> Enum.map(fn {_lead_id, crash_info} ->
            Map.get(crash_info, :notification, "")
          end)
          |> Enum.filter(&(&1 != ""))
          |> Enum.join("\n\n")

        if crash_notifications != "" do
          Logger.info(
            "#{log_prefix(data)} Including #{map_size(data.pending_crash_decisions)} pending crash notifications in restart catch-up prompt"
          )

          """

          **Pending crash decisions buffered during restart:**

          #{crash_notifications}
          """
        else
          ""
        end
      else
        ""
      end

    catchup_text = """
    **SYSTEM NOTIFICATION: ForemanAgent restart recovery**

    You crashed and were automatically restarted. Your conversation history has been restored from the session log.

    **Current job state:**

    Active Leads:
    #{if active_leads_summary == "", do: "(none)", else: active_leads_summary}

    Deliverable outcomes:
    #{if deliverable_outcomes_summary == "", do: "(none)", else: deliverable_outcomes_summary}
    #{buffered_messages_section}#{crash_notifications_section}
    Please review the current state and continue coordinating the job. If any Leads were in progress, you may need to check their status or send steering instructions.
    """

    Logger.info("#{log_prefix(data)} Sending catch-up prompt to restarted ForemanAgent")

    # Send the catch-up prompt
    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, catchup_text)
    end
  end

  # Job status broadcasting for web UI agent roster

  # Helper to broadcast job status and return the result
  defp broadcast_and_return({:next_state, new_state, data}, _current_state) do
    broadcast_job_status(new_state, data)
    {:next_state, new_state, data}
  end

  defp broadcast_and_return({:keep_state, data}, current_state) do
    broadcast_job_status(current_state, data)
    {:keep_state, data}
  end

  # Broadcasts job status via Registry for web UI consumption.
  defp broadcast_job_status(state, data) do
    agent_statuses = build_agent_statuses(state, data)
    job_status_key = {:job_status, data.session_id}

    Registry.dispatch(Deft.Registry, job_status_key, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:job_status, agent_statuses})
      end
    end)

    :ok
  end

  # Builds the agent_statuses list for broadcasting to the web UI.
  # Returns a list of `%{id: String.t(), type: atom(), state: atom(), label: String.t()}`.
  defp build_agent_statuses(job_phase, data) when is_atom(job_phase) do
    # Foreman status
    foreman_state = map_job_phase_to_state(job_phase)

    foreman_status = %{
      id: "foreman",
      type: :foreman,
      state: foreman_state,
      label: "Foreman"
    }

    # Lead statuses
    lead_statuses =
      data.leads
      |> Enum.map(fn {lead_id, lead_info} ->
        %{
          id: lead_id,
          type: :lead,
          state: Map.get(lead_info, :agent_state, :implementing),
          label: "Lead #{lead_id}"
        }
      end)
      |> Enum.sort_by(& &1.id)

    # Runner status (aggregate count)
    runner_count = count_active_runners(data)

    runner_statuses =
      if runner_count > 0 do
        runner_state = infer_runner_state(job_phase)

        [
          %{
            id: "runners",
            type: :runner,
            state: runner_state,
            label: if(runner_count == 1, do: "Runner", else: "Runners (#{runner_count})")
          }
        ]
      else
        []
      end

    [foreman_status | lead_statuses] ++ runner_statuses
  end

  # Maps Foreman job_phase to display state for the web UI.
  defp map_job_phase_to_state(:asking), do: :asking
  defp map_job_phase_to_state(:planning), do: :planning
  defp map_job_phase_to_state(:researching), do: :researching
  defp map_job_phase_to_state(:decomposing), do: :planning
  defp map_job_phase_to_state(:executing), do: :executing
  defp map_job_phase_to_state(:verifying), do: :verifying
  defp map_job_phase_to_state(:complete), do: :complete

  # Counts active Runners across all task collections.
  defp count_active_runners(data) do
    research_count = length(Map.get(data, :research_tasks, []))
    merge_count = map_size(Map.get(data, :merge_resolution_tasks, %{}))
    test_count = map_size(Map.get(data, :post_merge_test_tasks, %{}))
    research_count + merge_count + test_count
  end

  # Infers Runner state based on job phase.
  defp infer_runner_state(:researching), do: :researching
  defp infer_runner_state(:verifying), do: :testing
  defp infer_runner_state(:executing), do: :implementing
  defp infer_runner_state(_), do: :implementing
end
