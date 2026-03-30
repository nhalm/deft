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
      site_log_pid: nil,
      leads: %{},
      lead_monitors: %{},
      research_tasks: [],
      plan: nil,
      blocked_leads: %{},
      started_leads: MapSet.new(),
      job_start_time: System.monotonic_time(:millisecond)
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
    # Create site log instance for this job
    jobs_dir = Project.jobs_dir(data.working_dir)
    job_dir = Path.join(jobs_dir, data.session_id)
    File.mkdir_p!(job_dir)

    sitelog_path = Path.join(job_dir, "sitelog.dets")

    {:ok, site_log_pid} =
      Store.start_link(
        name: {:sitelog, data.session_id},
        type: :sitelog,
        dets_path: sitelog_path
      )

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

    # Send initial prompt to ForemanAgent to start Q&A
    if data.foreman_agent_pid do
      Deft.Agent.prompt(data.foreman_agent_pid, data.prompt)
    else
      Logger.warning("ForemanAgent not yet available, will prompt when set")
    end

    :keep_state_and_data
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

  def handle_event(:enter, _old_state, :researching, _data) do
    Logger.info("Foreman entering :researching phase")
    # Research Runners will be spawned when ForemanAgent calls request_research tool
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :decomposing, _data) do
    Logger.info("Foreman entering :decomposing phase - waiting for plan approval")
    # Present plan to user, wait for approval
    # For now, stub implementation
    :keep_state_and_data
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

    # If we're in :asking and didn't send the initial prompt yet, send it now
    if state == :asking and data.prompt do
      Deft.Agent.prompt(agent_pid, data.prompt)
    end

    {:keep_state, data}
  end

  # Handle agent actions from ForemanAgent orchestration tools
  def handle_event(:info, {:agent_action, :ready_to_plan}, :asking, data) do
    Logger.info("ForemanAgent ready to plan, transitioning to :planning")
    {:next_state, :planning, data}
  end

  def handle_event(:info, {:agent_action, :research, topics}, :planning, data) do
    Logger.info("ForemanAgent requested research on topics: #{inspect(topics)}")
    # Spawn research Runners (stub for now)
    # When complete, transition to :decomposing
    {:next_state, :researching, data}
  end

  def handle_event(:info, {:agent_action, :plan, deliverables}, :researching, data) do
    Logger.info("ForemanAgent submitted plan with #{length(deliverables)} deliverables")
    data = Map.put(data, :plan, deliverables)

    # Write plan to site log
    if data.site_log_pid do
      Store.write(data.site_log_pid, "plan", deliverables)
    end

    {:next_state, :decomposing, data}
  end

  def handle_event(:info, {:agent_action, :spawn_lead, _deliverable}, :executing, _data) do
    Logger.info("ForemanAgent requested spawning Lead")
    # Spawn Lead (stub for now)
    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :unblock_lead, lead_id, _contract}, :executing, _data) do
    Logger.info("ForemanAgent unblocking Lead #{lead_id}")
    # Unblock Lead with contract (stub for now)
    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :steer_lead, lead_id, _content}, :executing, _data) do
    Logger.info("ForemanAgent steering Lead #{lead_id}")
    # Send steering to Lead (stub for now)
    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :abort_lead, lead_id}, :executing, _data) do
    Logger.info("ForemanAgent aborting Lead #{lead_id}")
    # Stop Lead (stub for now)
    :keep_state_and_data
  end

  # Handle user prompts during execution
  def handle_event(:cast, {:prompt, text}, state, data) do
    Logger.debug("User prompt received in #{state}: #{text}")

    # Forward user input to ForemanAgent
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
  def handle_event(:info, {:lead_message, type, content, metadata}, _state, data) do
    Logger.debug("Lead message received: #{type}")

    # Forward to ForemanAgent for reasoning
    if data.foreman_agent_pid do
      message = format_lead_message(type, content, metadata)
      Deft.Agent.prompt(data.foreman_agent_pid, message)
    end

    # Auto-promote certain message types to site log
    if type in [:contract, :decision, :critical_finding] and data.site_log_pid do
      Store.write(data.site_log_pid, to_string(type), %{
        content: content,
        metadata: metadata,
        timestamp: System.system_time(:millisecond)
      })
    end

    :keep_state_and_data
  end

  # Handle Lead process DOWN messages
  def handle_event(:info, {:DOWN, ref, :process, pid, reason}, _state, data) do
    case find_lead_by_monitor(data.lead_monitors, ref) do
      {:ok, lead_id} ->
        Logger.warning("Lead #{lead_id} (#{inspect(pid)}) crashed: #{inspect(reason)}")
        # Handle Lead crash, cleanup worktree
        # TODO: Implement Lead crash recovery
        :keep_state_and_data

      :not_found ->
        # Monitor might be for another process (e.g., Runner)
        :keep_state_and_data
    end
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

  defp build_planning_context(data) do
    """
    Job: #{data.session_id}
    Request: #{data.prompt}

    Analyze this request and determine what research is needed before planning the work decomposition.
    """
  end

  defp format_lead_message(type, content, metadata) do
    """
    Lead update (#{type}):
    #{inspect(content)}

    Metadata: #{inspect(metadata)}
    """
  end

  defp find_lead_by_monitor(monitors, ref) do
    case Enum.find(monitors, fn {_id, monitor_ref} -> monitor_ref == ref end) do
      {lead_id, _ref} -> {:ok, lead_id}
      nil -> :not_found
    end
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
