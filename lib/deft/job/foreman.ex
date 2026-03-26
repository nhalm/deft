defmodule Deft.Job.Foreman do
  @moduledoc """
  Foreman orchestrates job execution using a gen_statem with tuple states.

  The Foreman IS the Agent extended with orchestration states. State format:
  `{job_phase, agent_state}` where job_phase tracks the orchestration lifecycle
  and agent_state tracks the agent loop state (:idle, :calling, :streaming, :executing_tools).

  ## Job Phases

  - `:planning` — Analyzes the request, determines research needs
  - `:researching` — Spawns research Runners in parallel
  - `:decomposing` — Distills findings into deliverables, presents plan
  - `:executing` — Spawns Leads, monitors progress, steers
  - `:verifying` — Runs verification Runner (tests + review)
  - `:complete` — Squash-merges work, reports, cleans up

  ## Lead Message Handling

  The Foreman handles `{:lead_message, type, content, metadata}` messages from Leads
  in any state using handle_event fallback. Message types:

  - `:status`, `:decision`, `:artifact`, `:contract`, `:contract_revision`,
  - `:plan_amendment`, `:complete`, `:blocker`, `:error`, `:critical_finding`, `:finding`

  ## Single-Agent Fallback

  If the task is simple (1-2 files, <3 Runner tasks), the Foreman skips orchestration
  and executes directly by staying in agent loop states without spawning Leads.
  """

  @behaviour :gen_statem

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Store
  alias Deft.Project
  alias Deft.Git
  alias Deft.Git.Job, as: GitJob
  alias Deft.Job.LeadSupervisor
  alias Deft.Job.Runner
  alias Deft.Job.RateLimiter

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
  Starts the Foreman gen_statem.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:prompt` — Required. Initial user prompt/issue.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:runner_supervisor` — Required. PID/name of Task.Supervisor for Foreman's Runners.
  - `:working_dir` — Optional. Working directory for the project (defaults to File.cwd!()).
  - `:name` — Optional. Name for the gen_statem process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    prompt = Keyword.fetch!(opts, :prompt)
    rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
    runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    name = Keyword.get(opts, :name)
    resumed_plan = Keyword.get(opts, :resumed_plan)
    cli_pid = Keyword.get(opts, :cli_pid)

    # Build session file path for Foreman
    jobs_dir = Project.jobs_dir(working_dir)
    session_file_path = Path.join([jobs_dir, session_id, "foreman_session.jsonl"])

    initial_data = %{
      session_id: session_id,
      config: config,
      prompt: prompt,
      rate_limiter_pid: rate_limiter_pid,
      runner_supervisor: runner_supervisor,
      working_dir: working_dir,
      cli_pid: cli_pid,
      messages: [],
      leads: %{},
      current_message: nil,
      stream_ref: nil,
      stream_monitor_ref: nil,
      estimated_tokens: nil,
      tool_tasks: [],
      tool_call_buffers: %{},
      tool_results: [],
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      session_cost: 0.0,
      research_tasks: [],
      research_findings: [],
      research_timeout_ref: nil,
      verification_timeout_ref: nil,
      job_timeout_ref: nil,
      site_log_pid: nil,
      started_site_log: false,
      plan: resumed_plan,
      blocked_leads: %{},
      started_leads: MapSet.new(),
      cost_ceiling_reached: false,
      decisions: [],
      session_file_path: session_file_path,
      saved_message_ids: MapSet.new(),
      merge_resolution_tasks: %{},
      post_merge_test_tasks: %{}
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Sends a prompt to the Foreman.
  """
  def prompt(foreman, text) do
    :gen_statem.cast(foreman, {:prompt, text})
  end

  @doc """
  Aborts the current job.
  """
  def abort(foreman) do
    :gen_statem.cast(foreman, :abort)
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
  Resumes a job from persisted state (plan.json and sitelog.dets).

  Reads the approved work plan and site log, determines which deliverables
  are complete, and starts fresh Leads for incomplete deliverables.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:runner_supervisor` — Required. PID of the RunnerSupervisor.
  - `:working_dir` — Optional. Working directory for the project (defaults to File.cwd!()).
  """
  @spec resume(Keyword.t()) :: {:ok, pid()} | {:error, term()}
  def resume(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    jobs_dir = Project.jobs_dir(working_dir)
    job_dir = Path.join(jobs_dir, session_id)
    plan_path = Path.join(job_dir, "plan.json")

    # Check if plan.json exists
    if File.exists?(plan_path) do
      # Read and parse plan.json
      case File.read(plan_path) do
        {:ok, json_content} ->
          case Jason.decode(json_content) do
            {:ok, plan_data} ->
              # Start Foreman with plan loaded
              config = Keyword.fetch!(opts, :config)
              rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
              runner_supervisor = Keyword.fetch!(opts, :runner_supervisor)

              # Convert plan data to the expected format
              plan = parse_plan_from_json(plan_data)

              # Start Foreman with resume: true flag to trigger resume logic
              start_link(
                session_id: session_id,
                config: Map.put(config, :resume, true),
                prompt: "Resuming job #{session_id}",
                rate_limiter_pid: rate_limiter_pid,
                runner_supervisor: runner_supervisor,
                working_dir: working_dir,
                resumed_plan: plan
              )

            {:error, reason} ->
              {:error, {:invalid_plan_json, reason}}
          end

        {:error, reason} ->
          {:error, {:plan_read_failed, reason}}
      end
    else
      {:error, :plan_not_found}
    end
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(initial_data) do
    # Create site log instance for curated job knowledge
    site_log_name = {:sitelog, initial_data.session_id}
    foreman_name = {:foreman, initial_data.session_id}

    # Register ourselves for site log access control
    {:ok, _} = Registry.register(Deft.ProcessRegistry, foreman_name, nil)

    # Look up the already-started site log instance (started by Deft.Job.Supervisor)
    # In tests, the Store may not be started yet (Foreman started in isolation), so start it if needed
    site_log_via = {:via, Registry, {Deft.ProcessRegistry, site_log_name}}
    site_log_pid = GenServer.whereis(site_log_via)

    {site_log_pid, started_site_log} =
      if site_log_pid == nil do
        # Store not started yet (e.g., in tests) - start it now
        jobs_dir = Project.jobs_dir(initial_data.working_dir)
        sitelog_path = Path.join([jobs_dir, initial_data.session_id, "sitelog.dets"])

        {:ok, pid} =
          Store.start_link(
            name: site_log_name,
            type: :sitelog,
            dets_path: sitelog_path,
            owner_name: foreman_name
          )

        {pid, true}
      else
        {site_log_pid, false}
      end

    data = %{initial_data | site_log_pid: site_log_pid, started_site_log: started_site_log}

    # Set up job-level timeout
    job_max_duration = Map.get(initial_data.config, :job_max_duration, 1_800_000)
    job_timeout_ref = Process.send_after(self(), :job_timeout, job_max_duration)
    data = %{data | job_timeout_ref: job_timeout_ref}

    # Check if we're resuming
    if Map.get(initial_data.config, :resume) && initial_data.plan do
      Logger.info(
        "#{log_prefix(initial_data.session_id)} Resuming job #{initial_data.session_id}"
      )

      # Build dependency structures from the resumed plan
      data = store_plan_and_build_dependencies(initial_data.plan, data)

      # Determine which deliverables are complete by checking site log
      completed_deliverables = determine_completed_deliverables(data)

      Logger.info(
        "#{log_prefix(initial_data.session_id)} Completed deliverables: #{inspect(completed_deliverables)}"
      )

      # Update started_leads to reflect completed work
      started_leads = MapSet.new(completed_deliverables)
      data = %{data | started_leads: started_leads}

      # Start in executing phase, ready to resume incomplete work
      initial_state = {:executing, :idle}
      {:ok, initial_state, data}
    else
      Logger.info(
        "#{log_prefix(initial_data.session_id)} Job started (#{initial_data.session_id}, #{initial_data.prompt})"
      )

      # Normal start in planning phase, idle agent state
      initial_state = {:planning, :idle}
      {:ok, initial_state, data}
    end
  end

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    # Clean up the site log Store if we started it directly (e.g., in tests or resume)
    # When started by the supervisor, the supervisor handles cleanup
    if data.started_site_log && data.site_log_pid do
      if Process.alive?(data.site_log_pid) do
        Logger.info(
          "#{log_prefix(data.session_id)} Foreman terminating: stopping site log Store for cleanup"
        )

        GenServer.stop(data.site_log_pid, :normal, 5000)
      end
    end

    :ok
  end

  @impl :gen_statem
  # State entry handlers
  def handle_event(:enter, _old_state, {:planning, :idle} = state, data) do
    # When entering planning phase, build a structured planning prompt
    # that asks the LLM to analyze the request and determine research tasks
    broadcast_job_status(state, data)
    planning_prompt = build_planning_prompt(data.prompt)
    :gen_statem.cast(self(), {:prompt, planning_prompt})
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {:researching, :idle} = state, data) do
    # Spawn research Runners in parallel
    Logger.info("#{log_prefix(data.session_id)} Foreman starting research phase")
    broadcast_job_status(state, data)

    # Use research task specs from planning phase if available, otherwise fall back to defaults
    research_specs =
      case Map.get(data, :research_task_specs) do
        nil ->
          Logger.info(
            "#{log_prefix(data.session_id)} No research tasks from planning, using defaults"
          )

          determine_research_tasks(data.prompt)

        specs ->
          Logger.info(
            "#{log_prefix(data.session_id)} Using #{length(specs)} research tasks from planning phase"
          )

          specs
      end

    # Get research timeout from config (default 120s)
    research_timeout = Map.get(data.config, :job_research_timeout, 120_000)

    # Spawn research Runners via Task.Supervisor.async_nolink
    tasks =
      Enum.map(research_specs, fn %{instructions: instructions, context: context} ->
        task =
          Task.Supervisor.async_nolink(
            data.runner_supervisor,
            fn ->
              # Get research runner model from config (defaults to same as lead model)
              research_model =
                Map.get(
                  data.config,
                  :job_research_runner_model,
                  Map.get(data.config, :job_lead_model)
                )

              provider_name = Map.get(data.config, :provider, "anthropic")

              runner_config = %{
                provider: get_provider(data),
                provider_name: provider_name,
                model: research_model
              }

              # Call Runner with :research type (read-only tools)
              Runner.run(
                :research,
                instructions,
                context,
                data.session_id,
                runner_config,
                data.working_dir
              )
            end
          )

        # Monitor the task for timeout
        Process.monitor(task.pid)
        task
      end)

    # Set timeout timer
    timeout_ref = Process.send_after(self(), :research_timeout, research_timeout)

    data = %{
      data
      | research_tasks: tasks,
        research_findings: [],
        research_timeout_ref: timeout_ref
    }

    # Broadcast updated status with Runners
    broadcast_job_status(state, data)

    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, {:decomposing, :idle} = state, data) do
    # When entering decomposing phase, prompt the Foreman to create a work plan
    Logger.info("#{log_prefix(data.session_id)} Foreman starting decomposition phase")
    broadcast_job_status(state, data)
    :gen_statem.cast(self(), :start_decomposition)
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {:executing, :idle} = state, data) do
    # When entering executing phase, create job branch first (unless resuming), then start all ready Leads
    Logger.info("#{log_prefix(data.session_id)} Foreman starting execution phase")
    broadcast_job_status(state, data)

    # Check if we're resuming - if so, skip branch creation (branch already exists)
    if Map.get(data.config, :resume) do
      Logger.info("#{log_prefix(data.session_id)} Resuming - skipping job branch creation")
      :gen_statem.cast(self(), :start_ready_leads)
      :keep_state_and_data
    else
      # Create job branch for Lead worktrees to branch from
      case GitJob.create_job_branch(job_id: data.session_id, auto_approve: true) do
        {:ok, branch_name, original_branch} ->
          Logger.info(
            "#{log_prefix(data.session_id)} Created job branch: #{branch_name} from #{original_branch}"
          )

          # Store original branch in config for later squash-merge
          updated_config = Map.put(data.config, :original_branch, original_branch)
          updated_data = %{data | config: updated_config}
          :gen_statem.cast(self(), :start_ready_leads)
          {:keep_state, updated_data}

        {:error, reason} ->
          Logger.error(
            "#{log_prefix(data.session_id)} Failed to create job branch: #{inspect(reason)}"
          )

          :gen_statem.cast(self(), {:job_failed, reason})
          :keep_state_and_data
      end
    end
  end

  def handle_event(:cast, {:job_failed, reason}, _state, data) do
    Logger.error("#{log_prefix(data.session_id)} Job failed: #{inspect(reason)}")
    data = cancel_job_timeout(data)
    {:next_state, {:complete, :idle}, data}
  end

  def handle_event(:cast, {:no_tools_return_idle, job_phase}, _state, data) do
    {:next_state, {job_phase, :idle}, data}
  end

  def handle_event(:enter, _old_state, {:verifying, :idle} = state, data) do
    # When entering verification phase, spawn verification Runner
    Logger.info("#{log_prefix(data.session_id)} Foreman starting verification phase")
    broadcast_job_status(state, data)
    :gen_statem.cast(self(), :start_verification)
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {job_phase, :executing_tools}, data) do
    # Extract tool calls from the last assistant message
    tool_calls = extract_tool_calls(data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls - return to idle in current job phase
      # Can't use {:next_state, ...} from state_enter, so cast to self
      :gen_statem.cast(self(), {:no_tools_return_idle, job_phase})
      :keep_state_and_data
    else
      # Execute tools
      tasks =
        Enum.map(tool_calls, fn tool_call ->
          Task.Supervisor.async_nolink(
            data.runner_supervisor,
            fn ->
              execute_tool(tool_call, data)
            end
          )
        end)

      {:keep_state, %{data | tool_tasks: tasks}}
    end
  end

  def handle_event(:enter, _old_state, _state, _data) do
    :keep_state_and_data
  end

  # Prompt handling
  def handle_event(:cast, {:prompt, text}, {job_phase, :idle}, data) do
    # Check if this is a job correction (explicit user course-correction)
    case String.split(text, "__JOB_CORRECTION__: ", parts: 2) do
      [_prefix, correction_content] ->
        # This is a correction - auto-promote to site log
        Logger.info(
          "#{log_prefix(data.session_id)} User correction received: #{correction_content}"
        )

        metadata = %{source: "user", timestamp: DateTime.utc_now()}
        write_to_site_log(:correction, correction_content, metadata, data)

        # Send acknowledgment message to user
        data = send_user_message("Correction recorded and promoted to site log.", data)

        # Stay in idle state
        {:keep_state, data}

      [_] ->
        # Normal prompt - proceed with LLM call
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

            {:next_state, {job_phase, :calling}, data}

          {:error, reason} ->
            Logger.error(
              "#{log_prefix(data.session_id)} Foreman LLM call failed in #{job_phase}: #{inspect(reason)}"
            )

            {:next_state, {:complete, :idle}, data}
        end
    end
  end

  # Decomposition handling
  def handle_event(:cast, :start_decomposition, {:decomposing, :idle}, data) do
    # Build decomposition prompt with research findings
    decomposition_prompt = build_decomposition_prompt(data)

    # Add user message with decomposition request
    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Deft.Message.Text{text: decomposition_prompt}],
      timestamp: DateTime.utc_now()
    }

    messages = data.messages ++ [user_message]

    # Start LLM call
    data = %{data | messages: messages, turn_count: data.turn_count + 1}

    case call_llm(data) do
      {:ok, stream_ref, monitor_ref, estimated_tokens} ->
        data = %{
          data
          | stream_ref: stream_ref,
            stream_monitor_ref: monitor_ref,
            estimated_tokens: estimated_tokens
        }

        {:next_state, {:decomposing, :calling}, data}

      {:error, reason} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Foreman LLM call failed in decomposition: #{inspect(reason)}"
        )

        {:next_state, {:complete, :idle}, data}
    end
  end

  # Start ready Leads handling
  def handle_event(:cast, :start_ready_leads, {:executing, :idle}, data) do
    # Check if cost ceiling has been reached
    if data.cost_ceiling_reached do
      Logger.info(
        "#{log_prefix(data.session_id)} Cost ceiling reached - not starting new Leads until spending approved"
      )

      {:keep_state_and_data}
    else
      # Get max_leads config (default 5)
      max_leads = Map.get(data.config, :job_max_leads, 5)

      # Count currently active leads
      active_leads = map_size(data.leads)

      # Calculate how many new leads can be started
      available_slots = max(0, max_leads - active_leads)

      # Determine which Leads can start immediately (no dependencies or dependencies satisfied)
      ready_deliverables = get_ready_deliverables(data)

      # Limit to available slots
      deliverables_to_start = Enum.take(ready_deliverables, available_slots)

      if available_slots == 0 and length(ready_deliverables) > 0 do
        Logger.info(
          "#{log_prefix(data.session_id)} Max concurrent Leads reached (#{max_leads}) - deferring #{length(ready_deliverables)} ready deliverable(s)"
        )
      end

      # Start each ready Lead
      updated_data =
        Enum.reduce(deliverables_to_start, data, fn deliverable, acc_data ->
          start_lead(deliverable, acc_data)
        end)

      # Broadcast updated status with new Leads
      broadcast_job_status({:executing, :idle}, updated_data)

      {:keep_state, updated_data}
    end
  end

  # Start verification Runner handling
  def handle_event(:cast, :start_verification, {:verifying, :idle}, data) do
    Logger.info(
      "#{log_prefix(data.session_id)} Spawning verification Runner for final testing and review"
    )

    # Get job branch for testing
    job_branch = "deft/job-#{data.session_id}"

    # Get test command from config (defaults to "mix test")
    test_command = Map.get(data.config, :job_test_command, "mix test")

    # Get runner model from config
    runner_model = Map.get(data.config, :job_runner_model, Map.get(data.config, :job_lead_model))

    # Get verification timeout from config (default 300s)
    job_runner_timeout = Map.get(data.config, :job_runner_timeout, 300_000)

    # Build verification instructions
    verification_instructions = """
    Run the full test suite and review all modified files for quality.

    1. Run the test suite: #{test_command}
    2. Review the modified files in this job for:
       - Code quality and adherence to project conventions
       - Potential bugs or issues
       - Test coverage

    If all tests pass and the code looks good, report success.
    If tests fail or there are quality issues, report the failures with details.
    """

    verification_context = """
    Job branch: #{job_branch}
    Test command: #{test_command}
    """

    provider_name = Map.get(data.config, :provider, "anthropic")

    runner_config = %{
      provider: get_provider(data),
      provider_name: provider_name,
      model: runner_model
    }

    # Spawn verification Runner
    task =
      Task.Supervisor.async_nolink(
        data.runner_supervisor,
        fn ->
          Runner.run(
            :testing,
            verification_instructions,
            verification_context,
            data.session_id,
            runner_config,
            data.working_dir
          )
        end
      )

    # Monitor the task
    Process.monitor(task.pid)

    # Set timeout timer
    timeout_ref = Process.send_after(self(), :verification_timeout, job_runner_timeout)

    # Store verification task and timeout ref
    {:keep_state, %{data | tool_tasks: [task], verification_timeout_ref: timeout_ref}}
  end

  # Abort handling (works in any state)
  def handle_event(:cast, :abort, {_job_phase, _agent_state}, data) do
    Logger.info("#{log_prefix(data.session_id)} Foreman aborting job")
    # Cancel any in-flight streams
    if data.stream_ref do
      cancel_stream(data)
    end

    # Terminate any in-flight tasks
    Enum.each(data.tool_tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    # Delegate git cleanup to GitJob.abort_job/1 which handles:
    # - Lead worktree removal
    # - Original branch restoration
    # - Job branch deletion (respecting keep_failed_branches config)
    # - Stash pop to restore user's uncommitted changes
    original_branch = Map.get(data.config, :original_branch, nil)
    keep_failed_branches = Map.get(data.config, :job_keep_failed_branches, false)

    GitJob.abort_job(
      job_id: data.session_id,
      original_branch: original_branch,
      working_dir: data.working_dir,
      keep_failed_branches: keep_failed_branches
    )

    # Archive job files for debugging
    archive_job_files(data.session_id, data.working_dir, :aborted)

    # Cancel job timeout timer and clear state
    data = cancel_job_timeout(data)
    data = %{data | stream_ref: nil, stream_monitor_ref: nil, tool_tasks: []}

    # Transition to complete phase
    {:next_state, {:complete, :idle}, data}
  end

  # Plan approval handling
  def handle_event(:cast, :approve_plan, {:decomposing, :idle}, data) do
    Logger.info(
      "#{log_prefix(data.session_id)} Plan approved by user, transitioning to execution phase"
    )

    # Store plan and build dependency structures if plan exists
    updated_data =
      if data.plan do
        store_plan_and_build_dependencies(data.plan, data)
      else
        Logger.warning(
          "#{log_prefix(data.session_id)} No plan available when approve_plan was called"
        )

        data
      end

    {:next_state, {:executing, :idle}, updated_data}
  end

  def handle_event(:cast, :reject_plan, {:decomposing, :idle}, data) do
    Logger.info("#{log_prefix(data.session_id)} Plan rejected by user, requesting revision")

    # Prompt the Foreman to revise the plan
    revision_prompt = """
    The user has rejected the proposed plan. Please revise the plan based on their feedback.

    Consider:
    - Are there better decomposition boundaries?
    - Should the work be split differently?
    - Are the dependencies correct?
    - Should this be executed as a single-agent task instead?
    """

    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Deft.Message.Text{text: revision_prompt}],
      timestamp: DateTime.utc_now()
    }

    messages = data.messages ++ [user_message]
    data = %{data | messages: messages, turn_count: data.turn_count + 1}

    # Start LLM call for revision
    case call_llm(data) do
      {:ok, stream_ref, monitor_ref, estimated_tokens} ->
        data = %{
          data
          | stream_ref: stream_ref,
            stream_monitor_ref: monitor_ref,
            estimated_tokens: estimated_tokens
        }

        {:next_state, {:decomposing, :calling}, data}

      {:error, reason} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Foreman LLM call failed in plan revision: #{inspect(reason)}"
        )

        {:next_state, {:complete, :idle}, data}
    end
  end

  # Lead message handling (available in any state)
  def handle_event(
        :info,
        {:lead_message, type, content, metadata},
        {job_phase, _agent_state} = state,
        data
      ) do
    Logger.info("#{log_prefix(data.session_id)} Foreman received lead message: #{type}")

    # Process the lead message (may update Lead state)
    data = process_lead_message(type, content, metadata, data)

    # Check if this message triggers a phase transition
    case check_phase_transition(type, job_phase, data) do
      {:transition, new_phase} ->
        new_state = {new_phase, :idle}
        broadcast_job_status(new_state, data)
        {:next_state, new_state, data}

      :no_transition ->
        # Broadcast even without phase transition, as Lead state may have changed
        broadcast_job_status(state, data)
        {:keep_state, data}
    end
  end

  # Stream process crash handling (DOWN message)
  def handle_event(
        :info,
        {:DOWN, monitor_ref, :process, _pid, reason},
        {job_phase, agent_state},
        data
      )
      when monitor_ref == data.stream_monitor_ref and agent_state in [:calling, :streaming] do
    Logger.error(
      "#{log_prefix(data.session_id)} Foreman: stream process crashed in #{agent_state} state, reason: #{inspect(reason)}"
    )

    # Cancel streaming state
    data = %{
      data
      | stream_ref: nil,
        stream_monitor_ref: nil,
        current_message: nil
    }

    # Transition to idle state to allow recovery
    {:next_state, {job_phase, :idle}, data}
  end

  # Task crash handling (DOWN message) - research runners, tool tasks, merge resolution, post-merge tests, and verification Runner
  def handle_event(
        :info,
        {:DOWN, _monitor_ref, :process, _pid, _reason} = down_msg,
        {job_phase, agent_state} = state,
        data
      ) do
    # Extract ref from DOWN message
    {:DOWN, ref, :process, _pid, reason} = down_msg

    # Check if this ref matches any research task
    research_tasks = Map.get(data, :research_tasks, [])
    crashed_research_task = Enum.find(research_tasks, fn task -> task.ref == ref end)

    # Check if this ref matches any tool task
    tool_tasks = Map.get(data, :tool_tasks, [])
    crashed_tool_task = Enum.find(tool_tasks, fn task -> task.ref == ref end)

    # Check if this ref matches any merge resolution task
    merge_resolution_tasks = Map.get(data, :merge_resolution_tasks, %{})
    crashed_merge_task = Map.get(merge_resolution_tasks, ref)

    # Check if this ref matches any post-merge test task
    post_merge_test_tasks = Map.get(data, :post_merge_test_tasks, %{})
    crashed_test_task = Map.get(post_merge_test_tasks, ref)

    cond do
      crashed_research_task ->
        handle_research_task_crash(ref, reason, job_phase, agent_state, data)

      crashed_tool_task ->
        handle_tool_task_crash(ref, reason, job_phase, agent_state, data)

      crashed_merge_task ->
        handle_merge_task_crash(ref, reason, crashed_merge_task, data)

      crashed_test_task ->
        handle_post_merge_test_crash(ref, reason, crashed_test_task, data)

      true ->
        # Not a research, tool, merge, or test task - fall through to Lead crash handler
        handle_lead_crash(down_msg, state, data)
    end
  end

  # Rate limiter messages
  def handle_event(:info, {:rate_limiter, :cost, amount}, {_job_phase, _agent_state}, data) do
    Logger.info("#{log_prefix(data.session_id)} Foreman cost checkpoint: $#{amount}")
    # RateLimiter sends cumulative cost, so replace instead of add
    {:keep_state, %{data | session_cost: amount}}
  end

  def handle_event(:info, {:rate_limiter, :cost_warning, cost}, {_job_phase, _agent_state}, data) do
    Logger.warning(
      "#{log_prefix(data.session_id)} Cost warning reached: $#{Float.round(cost, 2)}"
    )

    # Cost warning is just informational - no state change needed
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:rate_limiter, :concurrency_change, new_limit},
        {_job_phase, _agent_state},
        data
      ) do
    Logger.info("#{log_prefix(data.session_id)} Foreman concurrency change: #{new_limit}")
    # Store the new concurrency limit
    config = Map.put(data.config, :current_concurrency, new_limit)
    {:keep_state, %{data | config: config}}
  end

  def handle_event(
        :info,
        {:rate_limiter, :cost_ceiling_reached, cost},
        {_job_phase, _agent_state},
        data
      ) do
    Logger.warning(
      "#{log_prefix(data.session_id)} Cost ceiling reached: $#{Float.round(cost, 2)} - pausing new Lead spawns"
    )

    # Set flag to prevent new Lead spawns
    # In-flight Leads continue executing, but no new Leads will start
    # until user approves continued spending via RateLimiter.approve_continued_spending/1
    {:keep_state, %{data | cost_ceiling_reached: true}}
  end

  # Provider event handling during streaming
  def handle_event(:info, {:provider_event, event}, {job_phase, :calling}, data) do
    # First event received - transition to streaming
    data = process_provider_event(event, data)
    {:next_state, {job_phase, :streaming}, data}
  end

  def handle_event(:info, {:provider_event, event}, {job_phase, :streaming}, data) do
    data = process_provider_event(event, data)

    # Check if streaming is done
    if done_streaming?(event) do
      # Finalize message and transition to executing_tools
      data = finalize_streaming(data)
      {:next_state, {job_phase, :executing_tools}, data}
    else
      {:keep_state, data}
    end
  end

  # Research task completion
  def handle_event(
        :info,
        {ref, result},
        {:researching, _agent_state},
        %{research_tasks: tasks} = data
      )
      when is_reference(ref) do
    # A research task completed
    Logger.debug("#{log_prefix(data.session_id)} Research task completed: #{inspect(result)}")

    # Find and remove completed task
    tasks = Enum.reject(tasks, fn task -> task.ref == ref end)

    # Collect findings
    findings =
      case result do
        {:ok, output} ->
          data.research_findings ++ [output]

        {:error, reason} ->
          Logger.warning("#{log_prefix(data.session_id)} Research task failed: #{reason}")
          data.research_findings
      end

    data = %{data | research_tasks: tasks, research_findings: findings}

    # If all research tasks done, transition to decomposing
    if Enum.empty?(tasks) do
      # Cancel timeout timer
      if data.research_timeout_ref do
        Process.cancel_timer(data.research_timeout_ref)
      end

      Logger.info(
        "#{log_prefix(data.session_id)} Research phase complete, collected #{length(findings)} findings"
      )

      {:next_state, {:decomposing, :idle}, data}
    else
      {:keep_state, data}
    end
  end

  # Research timeout
  def handle_event(:info, :research_timeout, {:researching, _agent_state}, data) do
    Logger.warning(
      "#{log_prefix(data.session_id)} Research timeout reached, proceeding with #{length(data.research_findings)} findings"
    )

    # Kill any remaining research tasks
    Enum.each(data.research_tasks, fn task ->
      # Task is a struct with pid and ref fields
      if Process.alive?(task.pid) do
        Process.exit(task.pid, :kill)
      end
    end)

    # Transition to decomposing with whatever findings we have
    data = %{data | research_tasks: [], research_timeout_ref: nil}
    {:next_state, {:decomposing, :idle}, data}
  end

  # Verification timeout
  def handle_event(:info, :verification_timeout, {:verifying, :idle}, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Verification timeout reached - marking job as failed"
    )

    # Kill any remaining verification tasks
    Enum.each(data.tool_tasks, fn task ->
      # Task is a struct with pid and ref fields
      if Process.alive?(task.pid) do
        Process.exit(task.pid, :kill)
      end
    end)

    # Clean up all worktrees
    cleanup_all_lead_worktrees(data)

    unless Map.get(data.config, :job_keep_failed_branches, false) do
      delete_job_branch_on_failure(data.session_id, data.working_dir)
    end

    archive_job_files(data.session_id, data.working_dir, :verification_timeout)

    # Transition to complete with error
    data = %{data | tool_tasks: [], verification_timeout_ref: nil}
    {:next_state, {:complete, :idle}, data}
  end

  # Job-level timeout
  def handle_event(:info, :job_timeout, {_job_phase, _agent_state}, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Job timeout reached - aborting job after #{Map.get(data.config, :job_max_duration, 1_800_000)}ms"
    )

    # Cancel any in-flight streams
    if data.stream_ref do
      cancel_stream(data)
    end

    # Kill all running Leads
    Enum.each(data.leads, fn {lead_id, lead_info} ->
      if Process.alive?(lead_info.pid) do
        Logger.info("#{log_prefix(data.session_id)} Killing Lead #{lead_id} due to job timeout")
        Process.exit(lead_info.pid, :kill)
      end
    end)

    # Terminate any in-flight tasks
    Enum.each(data.tool_tasks, fn task ->
      if Process.alive?(task.pid) do
        Process.exit(task.pid, :kill)
      end
    end)

    # Clean up all Lead worktrees
    cleanup_all_lead_worktrees(data)

    # Delete job branch unless configured to keep it
    unless Map.get(data.config, :job_keep_failed_branches, false) do
      delete_job_branch_on_failure(data.session_id, data.working_dir)
    end

    # Archive job files for debugging
    archive_job_files(data.session_id, data.working_dir, :job_timeout)

    # Transition to complete phase
    data = %{
      data
      | stream_ref: nil,
        stream_monitor_ref: nil,
        tool_tasks: [],
        job_timeout_ref: nil
    }

    {:next_state, {:complete, :idle}, data}
  end

  # Tool task completion
  def handle_event(
        :info,
        {ref, results},
        {job_phase, :executing_tools},
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
        case call_llm(data) do
          {:ok, stream_ref, monitor_ref, estimated_tokens} ->
            data = %{
              data
              | stream_ref: stream_ref,
                stream_monitor_ref: monitor_ref,
                estimated_tokens: estimated_tokens
            }

            {:next_state, {job_phase, :calling}, data}

          {:error, reason} ->
            Logger.error(
              "#{log_prefix(data.session_id)} Foreman LLM call failed in #{job_phase}: #{inspect(reason)}"
            )

            {:next_state, {:complete, :idle}, data}
        end
      else
        # Check if we need to transition to next phase
        {next_state, updated_data} = determine_next_phase(job_phase, data)
        {:next_state, next_state, updated_data}
      end
    else
      {:keep_state, data}
    end
  end

  # Merge-resolution task completion
  def handle_event(
        :info,
        {ref, result},
        {:executing, _agent_state},
        %{merge_resolution_tasks: tasks} = data
      )
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _tasks} ->
        # Not a merge-resolution task, ignore
        :keep_state_and_data

      {task_context, remaining_tasks} ->
        %{
          lead_id: lead_id,
          lead_info: lead_info,
          conflicted_files: conflicted_files,
          merge_worktree_path: merge_worktree_path
        } = task_context

        # Get retry_count with default 0 for backward compatibility
        retry_count = Map.get(task_context, :retry_count, 0)

        data = %{data | merge_resolution_tasks: remaining_tasks}

        # Clean up the merge worktree (where conflicts were resolved)
        cleanup_worktree(merge_worktree_path, data.working_dir, data.session_id)

        # Max retry attempts for merge-resolution (per spec section 3)
        max_retries = 3

        case result do
          {:ok, _output} ->
            handle_merge_resolution_success(
              lead_id,
              lead_info,
              conflicted_files,
              retry_count,
              max_retries,
              data
            )

          {:error, reason} ->
            Logger.error(
              "#{log_prefix(data.session_id)} Merge-resolution Runner failed for Lead #{lead_id}: #{inspect(reason)}"
            )

            send_to_self =
              {:lead_message, :critical_finding,
               "Merge conflict for Lead #{lead_id} could not be automatically resolved: #{Enum.join(conflicted_files, ", ")}. Manual intervention required.\n\nRunner error: #{inspect(reason)}",
               %{lead_id: lead_id, conflicted_files: conflicted_files}}

            send(self(), send_to_self)

            # Clean up the Lead's worktree
            cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

            # Remove Lead from tracking
            leads = Map.delete(data.leads, lead_id)
            {:keep_state, %{data | leads: leads}}
        end
    end
  end

  # Post-merge test task completion
  def handle_event(
        :info,
        {ref, result},
        {:executing, _agent_state},
        %{post_merge_test_tasks: tasks} = data
      )
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _tasks} ->
        # Not a post-merge test task, ignore
        :keep_state_and_data

      {task_context, remaining_tasks} ->
        %{
          lead_id: lead_id,
          lead_info: lead_info
        } = task_context

        data = %{data | post_merge_test_tasks: remaining_tasks}

        case result do
          {:ok, :passed} ->
            new_data = handle_test_success(lead_id, lead_info, data)

            # Check if all Leads are complete after test success
            case check_phase_transition(:complete, :executing, new_data) do
              {:transition, new_phase} ->
                {:next_state, {new_phase, :idle}, new_data}

              :no_transition ->
                {:keep_state, new_data}
            end

          {:error, :test_failed, test_output} ->
            new_data = handle_test_failure(lead_id, lead_info, test_output, data)
            {:keep_state, new_data}

          {:error, reason} ->
            new_data = handle_test_error(lead_id, lead_info, reason, data)
            {:keep_state, new_data}
        end
    end
  end

  # Verification task completion
  def handle_event(
        :info,
        {ref, results},
        {:verifying, _agent_state},
        %{tool_tasks: tasks} = data
      )
      when is_reference(ref) do
    # Verification Runner completed
    tasks = Enum.reject(tasks, fn task -> task.ref == ref end)
    data = %{data | tool_tasks: tasks}

    # Cancel timeout timer
    if data.verification_timeout_ref do
      Process.cancel_timer(data.verification_timeout_ref)
    end

    data = %{data | verification_timeout_ref: nil}

    Logger.info("#{log_prefix(data.session_id)} Verification Runner completed")

    # Check verification results
    verification_passed = analyze_verification_results(results, data.session_id)

    if verification_passed do
      Logger.info(
        "#{log_prefix(data.session_id)} Verification passed - proceeding with squash-merge"
      )

      # Get original branch (stored in config or default to current branch)
      original_branch = Map.get(data.config, :original_branch, "main")

      # Get squash setting from config (default true per git-strategy.md section 7)
      squash = Map.get(data.config, :job_squash_on_complete, true)

      # Trigger squash-merge
      case GitJob.complete_job(
             job_id: data.session_id,
             original_branch: original_branch,
             squash: squash,
             working_dir: data.working_dir
           ) do
        {:ok, :completed} ->
          Logger.info(
            "#{log_prefix(data.session_id)} Job completed successfully - squash-merge done"
          )

          # Clean up any remaining Lead worktrees
          cleanup_all_lead_worktrees(data)

          # Archive job files for debugging
          archive_job_files(data.session_id, data.working_dir, :completed)

          # Cancel job timeout timer
          data = cancel_job_timeout(data)

          {:next_state, {:complete, :idle}, data}

        {:error, {:worktrees_remain, count}} ->
          # Merge succeeded and branch was deleted, but orphan worktrees remain
          Logger.warning(
            "#{log_prefix(data.session_id)} Job completed but #{count} orphan worktrees remain"
          )

          # Clean up any remaining Lead worktrees
          cleanup_all_lead_worktrees(data)

          # Archive job files for debugging
          archive_job_files(data.session_id, data.working_dir, :completed)

          # Report as a warning, not a failure
          warning_message = """
          Job completed successfully, but #{count} orphan worktrees were detected.

          These are likely from incomplete cleanup and can be removed with:
            git worktree list
            git worktree remove <path>
          """

          data = send_user_message(warning_message, data)

          # Cancel job timeout timer
          data = cancel_job_timeout(data)

          {:next_state, {:complete, :idle}, data}

        {:error, reason} ->
          Logger.error(
            "#{log_prefix(data.session_id)} Failed to complete job: #{inspect(reason)}"
          )

          # Clean up any remaining Lead worktrees even on merge failure
          cleanup_all_lead_worktrees(data)

          # Archive job files for debugging
          archive_job_files(data.session_id, data.working_dir, :merge_failed)

          # Report error to user
          error_message = """
          Verification passed but failed to merge changes: #{inspect(reason)}

          You may need to manually merge the job branch: deft/job-#{data.session_id}
          """

          data = send_user_message(error_message, data)

          # Cancel job timeout timer
          data = cancel_job_timeout(data)

          {:next_state, {:complete, :idle}, data}
      end
    else
      Logger.warning("#{log_prefix(data.session_id)} Verification failed")

      # Clean up all Lead worktrees
      cleanup_all_lead_worktrees(data)

      # Delete job branch unless configured to keep it
      keep_branch = Map.get(data.config, :job_keep_failed_branches, false)

      unless keep_branch do
        delete_job_branch_on_failure(data.session_id, data.working_dir)
      end

      # Archive job files for debugging
      archive_job_files(data.session_id, data.working_dir, :verification_failed)

      # Identify responsible Lead based on test failures
      responsible_lead = identify_responsible_lead(results, data)

      # Build failure message, noting if branch was kept
      branch_status =
        if keep_branch do
          "The job has been stopped. Changes remain in the job branch: deft/job-#{data.session_id}\nYou can review the changes and decide how to proceed."
        else
          "The job has been stopped and the job branch has been deleted.\nChanges were not merged to your original branch."
        end

      # Report failure to user
      failure_message = """
      Verification failed. Test suite or code review found issues.

      #{format_verification_failures(results)}

      #{if responsible_lead, do: "Most likely responsible: #{responsible_lead}", else: ""}

      #{branch_status}
      """

      data = send_user_message(failure_message, data)

      # Cancel job timeout timer
      data = cancel_job_timeout(data)

      {:next_state, {:complete, :idle}, data}
    end
  end

  # Ignore job_status broadcasts (these are for TUI subscribers, not the Foreman itself)
  def handle_event(:info, {:job_status, _agent_statuses}, _state, _data) do
    :keep_state_and_data
  end

  # Catch-all for unhandled events
  def handle_event(event_type, event_content, state, data) do
    Logger.debug(
      "#{log_prefix(data.session_id)} Unhandled event: #{event_type} #{inspect(event_content)} in state #{inspect(state)}"
    )

    :keep_state_and_data
  end

  # Private helpers

  defp handle_research_task_crash(ref, reason, job_phase, agent_state, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Research task crashed in #{job_phase}:#{agent_state}, reason: #{inspect(reason)}"
    )

    # Remove crashed task from tracking
    research_tasks = Map.get(data, :research_tasks, [])
    remaining_tasks = Enum.reject(research_tasks, fn task -> task.ref == ref end)
    data = %{data | research_tasks: remaining_tasks}

    # If all research tasks done (including crashed ones), transition to decomposing
    if Enum.empty?(remaining_tasks) do
      # Cancel timeout timer
      if data.research_timeout_ref do
        Process.cancel_timer(data.research_timeout_ref)
      end

      Logger.info(
        "#{log_prefix(data.session_id)} Research phase complete (with crashes), collected #{length(data.research_findings)} findings"
      )

      {:next_state, {:decomposing, :idle}, data}
    else
      {:keep_state, data}
    end
  end

  defp handle_tool_task_crash(ref, reason, job_phase, agent_state, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Tool task crashed in #{job_phase}:#{agent_state}, reason: #{inspect(reason)}"
    )

    # Remove crashed task from tracking
    tool_tasks = Map.get(data, :tool_tasks, [])
    remaining_tasks = Enum.reject(tool_tasks, fn task -> task.ref == ref end)
    data = %{data | tool_tasks: remaining_tasks}

    case job_phase do
      :verifying ->
        handle_verification_crash(data)

      _other_phase ->
        # For other phases, just keep state with updated task list
        # The normal flow will detect incomplete tasks and handle appropriately
        {:keep_state, data}
    end
  end

  defp handle_merge_task_crash(ref, reason, task_context, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Merge resolution task crashed, reason: #{inspect(reason)}"
    )

    %{
      lead_id: lead_id,
      lead_info: lead_info,
      conflicted_files: conflicted_files,
      merge_worktree_path: merge_worktree_path
    } = task_context

    # Remove crashed task from tracking
    merge_resolution_tasks = Map.delete(data.merge_resolution_tasks, ref)
    data = %{data | merge_resolution_tasks: merge_resolution_tasks}

    # Clean up the merge worktree (where conflicts were resolved)
    cleanup_worktree(merge_worktree_path, data.working_dir, data.session_id)

    # Send critical finding for user intervention
    send_to_self =
      {:lead_message, :critical_finding,
       "Merge conflict resolution Runner crashed for Lead #{lead_id}. Manual intervention required.\n\nConflicted files: #{Enum.join(conflicted_files, ", ")}\n\nCrash reason: #{inspect(reason)}",
       %{lead_id: lead_id, conflicted_files: conflicted_files}}

    send(self(), send_to_self)

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Remove Lead from tracking to prevent job hang
    leads = Map.delete(data.leads, lead_id)
    {:keep_state, %{data | leads: leads}}
  end

  defp handle_post_merge_test_crash(ref, reason, task_context, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Post-merge test task crashed, reason: #{inspect(reason)}"
    )

    %{
      lead_id: lead_id,
      lead_info: lead_info
    } = task_context

    # Remove crashed task from tracking
    post_merge_test_tasks = Map.delete(data.post_merge_test_tasks, ref)
    data = %{data | post_merge_test_tasks: post_merge_test_tasks}

    # Treat crash as test error - use the same cleanup flow
    new_data = handle_test_error(lead_id, lead_info, {:test_execution_failed, reason}, data)
    {:keep_state, new_data}
  end

  defp handle_verification_crash(data) do
    # Verification Runner crashed - this is a critical failure
    Logger.error(
      "#{log_prefix(data.session_id)} Verification Runner crashed - marking job as failed"
    )

    # Cancel timeout timer
    if data.verification_timeout_ref do
      Process.cancel_timer(data.verification_timeout_ref)
    end

    data = %{data | verification_timeout_ref: nil}

    # Clean up all worktrees and transition to complete with error
    cleanup_all_lead_worktrees(data)

    unless Map.get(data.config, :job_keep_failed_branches, false) do
      delete_job_branch_on_failure(data.session_id, data.working_dir)
    end

    archive_job_files(data.session_id, data.working_dir, :verification_crash)

    # Cancel job timeout timer
    data = cancel_job_timeout(data)

    {:next_state, {:complete, :idle}, data}
  end

  defp handle_lead_crash(
         {:DOWN, monitor_ref, :process, _pid, reason},
         {job_phase, _agent_state} = _state,
         %{leads: leads} = data
       ) do
    # Find crashed Lead by monitor ref
    crashed_lead =
      Enum.find(leads, fn {_lead_id, info} ->
        info.monitor_ref == monitor_ref
      end)

    case crashed_lead do
      nil ->
        # Not a Lead monitor, ignore
        :keep_state_and_data

      {lead_id, lead_info} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Lead #{lead_id} crashed, cleaning up worktree: #{lead_info.worktree_path}, reason: #{inspect(reason)}"
        )

        # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
        deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

        # Write failure marker to site log to allow completion check to be satisfied
        write_failure_marker(lead_id, deliverable_name, "Lead crashed: #{inspect(reason)}", data)

        # Clean up the Lead's worktree
        cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

        # Remove crashed Lead from tracking
        leads = Map.delete(leads, lead_id)
        data = %{data | leads: leads}

        # Check if all Leads are complete after crash
        case check_phase_transition(:complete, job_phase, data) do
          {:transition, new_phase} ->
            {:next_state, {new_phase, :idle}, data}

          :no_transition ->
            {:keep_state, data}
        end
    end
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

    # Foreman uses read-only tools (same as Lead)
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
    # Build a Deft.Tool.Context struct for tool execution
    cache_config = %{
      "default" => 10_000,
      "read" => 20_000,
      "grep" => 8_000,
      "ls" => 4_000,
      "find" => 4_000
    }

    %Deft.Tool.Context{
      working_dir: data.working_dir,
      session_id: data.session_id,
      lead_id: "foreman",
      emit: fn _output -> :ok end,
      file_scope: nil,
      bash_timeout: 120_000,
      cache_tid: nil,
      cache_config: cache_config
    }
  end

  defp call_llm(data) do
    # Extract parameters from data
    job_id = data.session_id
    messages = data.messages
    config = data.config
    provider_name = Map.get(config, :provider, "anthropic")

    # Request permission from rate limiter
    case RateLimiter.request(job_id, provider_name, messages, :foreman) do
      {:ok, estimated_tokens} ->
        # Foreman uses read-only tools for planning and decomposition
        tools = [Deft.Tools.Read, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls]

        # Get the configured provider module
        provider_module = get_provider(data)

        # Use Foreman's model instead of session model
        foreman_model = Map.get(config, :job_foreman_model, "claude-sonnet-4-20250514")
        llm_config = Map.put(config, :model, foreman_model)

        # Start streaming from the provider
        case provider_module.stream(messages, tools, llm_config) do
          {:ok, stream_ref} ->
            # Monitor the stream process
            monitor_ref = Process.monitor(stream_ref)
            # Store estimated_tokens for later reconciliation
            {:ok, stream_ref, monitor_ref, estimated_tokens}

          {:error, reason} ->
            Logger.error(
              "#{log_prefix(data.session_id)} Foreman failed to start LLM stream: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Foreman failed to get rate limiter permission: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp cancel_stream(data) do
    if data.stream_ref do
      provider = get_provider(data)
      provider.cancel_stream(data.stream_ref)
      Logger.debug("#{log_prefix(data.session_id)} Cancelled stream: #{inspect(data.stream_ref)}")
    end

    :ok
  end

  defp cancel_job_timeout(data) do
    if data.job_timeout_ref do
      Process.cancel_timer(data.job_timeout_ref)
    end

    %{data | job_timeout_ref: nil}
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

  defp process_lead_message(:decision, content, metadata, data) do
    lead_id = Map.get(metadata, :lead_id)
    Logger.info("#{log_prefix(data.session_id)} Lead #{lead_id} decision: #{content}")

    # Auto-promote to site log
    write_to_site_log(:decision, content, metadata, data)

    # Record decision with timestamp
    decision = %{
      lead_id: lead_id,
      content: content,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    decisions = [decision | data.decisions]

    # Detect conflicts with recent decisions from other Leads
    conflicts = detect_decision_conflicts(decision, data.decisions, data.leads)

    if Enum.empty?(conflicts) do
      # No conflicts, store decision and continue
      %{data | decisions: decisions}
    else
      # Conflict detected
      Logger.warning(
        "#{log_prefix(data.session_id)} Decision conflict detected for Lead #{lead_id} with Leads: #{inspect(Enum.map(conflicts, & &1.lead_id))}"
      )

      # Pause all affected Leads (conflicting Lead + current Lead)
      affected_lead_ids = [lead_id | Enum.map(conflicts, & &1.lead_id)] |> Enum.uniq()
      data = pause_leads(affected_lead_ids, data)

      # Resolve conflict or escalate to user
      data = resolve_conflict(decision, conflicts, affected_lead_ids, data)

      %{data | decisions: decisions}
    end
  end

  defp process_lead_message(:contract, content, metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead published contract")
    # Auto-promote to site log
    write_to_site_log(:contract, content, metadata, data)

    # Check for blocked Leads that can now start
    # Extract which deliverable published this contract
    lead_id = Map.get(metadata, :lead_id)
    # Derive publishing_deliverable from the Lead tracking map
    publishing_deliverable =
      case Map.get(data.leads, lead_id) do
        %{deliverable: %{name: name}} -> name
        _ -> nil
      end

    # Check blocked_leads for any that depend on this contract
    unblocked_deliverables =
      data.blocked_leads
      |> Enum.filter(fn {_deliverable_name, contracts_needed} ->
        # Check if this contract satisfies any of the needed contracts
        Enum.any?(contracts_needed, fn needed_contract ->
          contract_matches?(needed_contract, publishing_deliverable, content)
        end)
      end)
      |> Enum.map(fn {deliverable_name, _} -> deliverable_name end)

    Logger.info(
      "#{log_prefix(data.session_id)} Contract from #{publishing_deliverable || lead_id} unblocked #{length(unblocked_deliverables)} deliverable(s)"
    )

    # Start each unblocked Lead (unless cost ceiling reached)
    updated_data =
      Enum.reduce(unblocked_deliverables, data, fn deliverable_name, acc_data ->
        # Find deliverable details from plan
        deliverable =
          Enum.find(acc_data.plan.deliverables, fn d ->
            d.name == deliverable_name
          end)

        if deliverable do
          # Remove from blocked_leads
          acc_data = %{
            acc_data
            | blocked_leads: Map.delete(acc_data.blocked_leads, deliverable_name)
          }

          # Start the Lead if cost ceiling not reached
          if acc_data.cost_ceiling_reached do
            Logger.info(
              "#{log_prefix(acc_data.session_id)} Cost ceiling reached - not starting unblocked Lead #{deliverable_name} until spending approved"
            )

            acc_data
          else
            start_lead(deliverable, acc_data)
          end
        else
          Logger.warning(
            "#{log_prefix(data.session_id)} Could not find deliverable #{deliverable_name} in plan"
          )

          acc_data
        end
      end)

    updated_data
  end

  defp process_lead_message(:critical_finding, content, metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead critical finding: #{content}")
    # Auto-promote to site log
    write_to_site_log(:critical_finding, content, metadata, data)
    data
  end

  defp process_lead_message(:finding, content, metadata, data) do
    Logger.debug("#{log_prefix(data.session_id)} Lead finding: #{inspect(content)}")

    # Promote if tagged as 'shared'
    if Map.get(metadata, :shared, false) do
      Logger.info("#{log_prefix(data.session_id)} Lead shared finding - promoting to site log")
      write_to_site_log(:research, content, metadata, data)
    end

    data
  end

  defp process_lead_message(:correction, content, metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} User correction received via Lead")
    # Auto-promote to site log
    write_to_site_log(:correction, content, metadata, data)
    data
  end

  defp process_lead_message(:status, _content, _metadata, data) do
    # Never promote status messages
    data
  end

  defp process_lead_message(:blocker, content, metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead blocker: #{content}")
    # Never promote blocker messages (coordination, not knowledge)
    # Update Lead state to :waiting
    lead_id = Map.get(metadata, :lead_id)
    update_lead_state(lead_id, :waiting, data)
  end

  defp process_lead_message(:artifact, content, _metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead artifact: #{inspect(content)}")
    # Log artifact creation/modification
    # Don't auto-promote to site log - these are tracked via git
    data
  end

  defp process_lead_message(:contract_revision, content, metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead contract revision")
    # Auto-promote to site log with revision flag
    write_to_site_log(:contract, content, Map.put(metadata, :revision, true), data)

    # Extract which deliverable published this contract revision
    publishing_deliverable = Map.get(metadata, :deliverable_name)

    # Find started Leads that depend on this contract
    dependent_leads =
      data.leads
      |> Enum.filter(fn {_lead_id, lead_info} ->
        # Check if this Lead's deliverable depends on the publishing deliverable
        lead_depends_on_contract?(lead_info.deliverable, publishing_deliverable, data.plan)
      end)
      |> Enum.map(fn {lead_id, _lead_info} -> lead_id end)

    Logger.info(
      "#{log_prefix(data.session_id)} Contract revision from #{publishing_deliverable || "unknown"} affects #{length(dependent_leads)} active Lead(s)"
    )

    # Send steering messages to dependent Leads
    Enum.each(dependent_leads, fn lead_id ->
      case Map.get(data.leads, lead_id) do
        nil ->
          Logger.warning(
            "#{log_prefix(data.session_id)} Could not find Lead #{lead_id} to re-steer"
          )

        lead_info ->
          steering_content = """
          INTERFACE CONTRACT REVISION

          The upstream deliverable "#{publishing_deliverable}" has revised its contract.

          Updated contract:
          #{content}

          Please review this revision and adjust your implementation accordingly.
          """

          # Send steering message to Lead process
          if lead_pid = Map.get(lead_info, :pid) do
            send(lead_pid, {:foreman_steering, steering_content})

            Logger.info(
              "#{log_prefix(data.session_id)} Sent contract revision steering to Lead #{lead_id}"
            )
          else
            Logger.warning(
              "#{log_prefix(data.session_id)} Lead #{lead_id} has no PID stored, cannot send steering (Lead process not yet started)"
            )
          end
      end
    end)

    data
  end

  defp process_lead_message(:plan_amendment, content, _metadata, data) do
    Logger.info("#{log_prefix(data.session_id)} Lead plan amendment request: #{content}")
    # Lead is requesting a change to the work plan
    # Don't auto-promote - this is a coordination request
    # TODO: evaluate amendment and decide whether to approve/adjust plan
    data
  end

  defp process_lead_message(:error, content, metadata, data) do
    Logger.error("#{log_prefix(data.session_id)} Lead error: #{content}")
    # Log the error but don't auto-promote to site log
    # Errors are handled in Lead crash recovery, not promoted as knowledge
    # Update Lead state to :error
    lead_id = Map.get(metadata, :lead_id)
    update_lead_state(lead_id, :error, data)
  end

  defp process_lead_message(:complete, _content, metadata, data) do
    lead_id = Map.get(metadata, :lead_id)
    deliverable_name = Map.get(metadata, :deliverable)

    Logger.info(
      "#{log_prefix(data.session_id)} Lead #{lead_id} completed deliverable: #{deliverable_name}"
    )

    # Update Lead state to :complete
    data = update_lead_state(lead_id, :complete, data)

    # Get Lead info for worktree cleanup
    lead_info = Map.get(data.leads, lead_id)

    if is_nil(lead_info) do
      Logger.warning(
        "#{log_prefix(data.session_id)} Lead #{lead_id} not found in tracking map, cannot merge"
      )

      data
    else
      handle_lead_merge(lead_id, lead_info, data)
    end
  end

  defp process_lead_message(type, content, _metadata, data) do
    Logger.debug("#{log_prefix(data.session_id)} Lead message (#{type}): #{inspect(content)}")
    data
  end

  # Handle merging a completed Lead's branch into the job branch
  defp handle_lead_merge(lead_id, lead_info, data) do
    handle_lead_merge_with_retry(lead_id, lead_info, data, 0)
  end

  defp handle_lead_merge_with_retry(lead_id, lead_info, data, retry_count) do
    case GitJob.merge_lead_branch(
           lead_id: lead_id,
           job_id: data.session_id,
           working_dir: data.working_dir
         ) do
      {:ok, :merged} ->
        Logger.info(
          "#{log_prefix(data.session_id)} Successfully merged Lead #{lead_id} into job branch"
        )

        handle_successful_merge(lead_id, lead_info, data)

      {:ok, :conflict, conflicted_files, merge_worktree_path} ->
        handle_merge_conflict(
          lead_id,
          conflicted_files,
          merge_worktree_path,
          lead_info,
          data,
          retry_count
        )

      {:error, reason} ->
        handle_merge_error(lead_id, reason, lead_info, data)
    end
  end

  # Handle successful merge by spawning async post-merge test task
  defp handle_successful_merge(lead_id, lead_info, data) do
    Logger.info(
      "#{log_prefix(data.session_id)} Spawning async post-merge test task for Lead #{lead_id}"
    )

    # Get test command from config (defaults to "mix test")
    test_command = Map.get(data.config, :job_test_command, "mix test")
    timeout = Map.get(data.config, :job_runner_timeout, 300_000)

    # Spawn async task for post-merge tests
    task =
      Task.Supervisor.async_nolink(data.runner_supervisor, fn ->
        GitJob.run_post_merge_tests(
          job_id: data.session_id,
          test_command: test_command,
          working_dir: data.working_dir,
          timeout: timeout
        )
      end)

    # Store task context for when it completes
    post_merge_test_tasks =
      Map.put(data.post_merge_test_tasks, task.ref, %{
        lead_id: lead_id,
        lead_info: lead_info
      })

    %{data | post_merge_test_tasks: post_merge_test_tasks}
  end

  # Handle successful post-merge tests
  defp handle_test_success(lead_id, lead_info, data) do
    Logger.info("#{log_prefix(data.session_id)} Post-merge tests passed for Lead #{lead_id}")

    # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
    deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

    # Write completion marker to site log for resume tracking
    # ONLY write after successful merge+test to prevent stale markers on failure
    metadata = %{lead_id: lead_id, deliverable: deliverable_name}
    write_to_site_log(:complete, "Deliverable #{deliverable_name} completed", metadata, data)

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Delete the Lead's branch
    delete_lead_branch(lead_id, data.working_dir, data.session_id)

    # Remove Lead from tracking
    leads = Map.delete(data.leads, lead_id)
    data = %{data | leads: leads}

    # Check if all Leads are done
    if all_leads_complete?(data) do
      Logger.info(
        "#{log_prefix(data.session_id)} All Leads complete, ready to transition to verification"
      )
    end

    data
  end

  # Handle post-merge test failure
  defp handle_test_failure(lead_id, lead_info, test_output, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Post-merge tests failed for Lead #{lead_id}. Manual intervention required."
    )

    # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
    deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

    # Write failure marker to site log to allow completion check to be satisfied
    write_failure_marker(
      lead_id,
      deliverable_name,
      "Post-merge tests failed",
      data
    )

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Delete the Lead's branch
    delete_lead_branch(lead_id, data.working_dir, data.session_id)

    # Remove Lead from tracking to prevent job hang
    leads = Map.delete(data.leads, lead_id)
    data = %{data | leads: leads}

    # Send critical finding for user intervention
    send_to_self =
      {:lead_message, :critical_finding,
       "Post-merge tests failed for Lead #{lead_id}. The merge was successful but tests now fail. Manual intervention or fix-up Runner needed.\n\nTest output:\n#{String.slice(test_output, 0, 1000)}",
       %{lead_id: lead_id, test_failed: true}}

    send(self(), send_to_self)

    data
  end

  # Handle post-merge test execution error
  defp handle_test_error(lead_id, lead_info, reason, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Failed to run post-merge tests for Lead #{lead_id}: #{inspect(reason)}"
    )

    # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
    deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

    # Write failure marker to site log to allow completion check to be satisfied
    write_failure_marker(
      lead_id,
      deliverable_name,
      "Test execution error: #{inspect(reason)}",
      data
    )

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Delete the Lead's branch
    delete_lead_branch(lead_id, data.working_dir, data.session_id)

    # Remove Lead from tracking to prevent job hang
    leads = Map.delete(data.leads, lead_id)
    data = %{data | leads: leads}

    # Send error message for user intervention
    send_to_self =
      {:lead_message, :error,
       "Failed to run post-merge tests for Lead #{lead_id}: #{inspect(reason)}",
       %{lead_id: lead_id}}

    send(self(), send_to_self)

    data
  end

  # Handle merge conflict
  defp handle_merge_conflict(
         lead_id,
         conflicted_files,
         merge_worktree_path,
         lead_info,
         data,
         retry_count
       ) do
    Logger.info(
      "#{log_prefix(data.session_id)} Merge conflict for Lead #{lead_id}, spawning merge-resolution Runner (attempt #{retry_count + 1})"
    )

    # Get runner model from config
    runner_model = Map.get(data.config, :job_runner_model, Map.get(data.config, :job_lead_model))

    provider_name = Map.get(data.config, :provider, "anthropic")

    runner_config = %{
      provider: get_provider(data),
      provider_name: provider_name,
      model: runner_model
    }

    # Build instructions for the merge-resolution Runner
    instructions = """
    Resolve the merge conflicts in the following files:
    #{Enum.join(conflicted_files, "\n")}

    The conflicts arose when merging Lead #{lead_id}'s work into the job branch.
    Review both sides of the conflict, understand the intent of each change,
    and resolve the conflicts to integrate both changes correctly.

    After resolving all conflicts, stage the resolved files using git add, then commit them with a merge commit message.
    """

    context = """
    Lead #{lead_id} completed its deliverable: #{lead_info.deliverable.name}
    Merge worktree path: #{merge_worktree_path}
    Conflicted files: #{Enum.join(conflicted_files, ", ")}
    """

    # Spawn merge-resolution Runner in the merge worktree (where conflict markers exist)
    task =
      Task.Supervisor.async_nolink(
        data.runner_supervisor,
        fn ->
          Runner.run(
            :merge_resolution,
            instructions,
            context,
            data.session_id,
            runner_config,
            merge_worktree_path
          )
        end
      )

    # Monitor the task
    Process.monitor(task.pid)

    # Store task context for when it completes
    merge_resolution_tasks =
      Map.put(data.merge_resolution_tasks, task.ref, %{
        lead_id: lead_id,
        lead_info: lead_info,
        conflicted_files: conflicted_files,
        merge_worktree_path: merge_worktree_path,
        retry_count: retry_count
      })

    %{data | merge_resolution_tasks: merge_resolution_tasks}
  end

  # Handle successful merge-resolution Runner completion
  defp handle_merge_resolution_success(
         lead_id,
         lead_info,
         conflicted_files,
         retry_count,
         max_retries,
         data
       ) do
    cond do
      retry_count >= max_retries - 1 ->
        handle_merge_retry_exhausted(lead_id, lead_info, conflicted_files, max_retries, data)

      true ->
        handle_merge_retry_attempt(lead_id, lead_info, retry_count, max_retries, data)
    end
  end

  # Handle merge retry exhaustion
  defp handle_merge_retry_exhausted(lead_id, lead_info, conflicted_files, max_retries, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Merge-resolution Runner exhausted max retries (#{max_retries}) for Lead #{lead_id}. Manual intervention required."
    )

    send_to_self =
      {:lead_message, :critical_finding,
       "Merge conflict for Lead #{lead_id} could not be automatically resolved after #{max_retries} attempts: #{Enum.join(conflicted_files, ", ")}. Manual intervention required.",
       %{lead_id: lead_id, conflicted_files: conflicted_files}}

    send(self(), send_to_self)

    # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
    deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

    # Write failure marker to site log to allow completion check to be satisfied
    write_failure_marker(
      lead_id,
      deliverable_name,
      "Merge conflict unresolved after #{max_retries} attempts",
      data
    )

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Delete the Lead's branch
    delete_lead_branch(lead_id, data.working_dir, data.session_id)

    # Remove Lead from tracking to prevent job hang
    leads = Map.delete(data.leads, lead_id)
    new_data = %{data | leads: leads}

    # Check if all Leads are complete after removing this one
    transition_or_keep_state(new_data, :complete, :executing)
  end

  # Handle merge retry attempt
  defp handle_merge_retry_attempt(lead_id, lead_info, retry_count, max_retries, data) do
    Logger.info(
      "#{log_prefix(data.session_id)} Merge-resolution Runner succeeded for Lead #{lead_id}, retrying merge (attempt #{retry_count + 1}/#{max_retries})"
    )

    # Retry the merge now that conflicts are resolved
    new_data = handle_lead_merge_with_retry(lead_id, lead_info, data, retry_count + 1)

    # Check if all Leads are complete after merge
    transition_or_keep_state(new_data, :complete, :executing)
  end

  # Helper to check phase transition and return appropriate state
  defp transition_or_keep_state(data, completion_status, current_phase) do
    case check_phase_transition(completion_status, current_phase, data) do
      {:transition, new_phase} ->
        {:next_state, {new_phase, :idle}, data}

      :no_transition ->
        {:keep_state, data}
    end
  end

  # Handle merge error
  defp handle_merge_error(lead_id, reason, lead_info, data) do
    Logger.error(
      "#{log_prefix(data.session_id)} Failed to merge Lead #{lead_id}: #{inspect(reason)}"
    )

    # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
    deliverable_name = String.replace_prefix(lead_id, "#{data.session_id}-", "")

    # Write failure marker to site log to allow completion check to be satisfied
    write_failure_marker(lead_id, deliverable_name, "Merge failed: #{inspect(reason)}", data)

    send_to_self =
      {:lead_message, :error, "Failed to merge Lead #{lead_id}: #{inspect(reason)}",
       %{lead_id: lead_id}}

    send(self(), send_to_self)

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir, data.session_id)

    # Remove Lead from tracking
    leads = Map.delete(data.leads, lead_id)
    %{data | leads: leads}
  end

  defp write_to_site_log(category, content, metadata, data) do
    # Generate a descriptive key for the site log entry
    key = generate_site_log_key(category, metadata)

    # Build the entry metadata
    entry_metadata = %{
      category: category,
      written_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Merge with any additional metadata from the Lead
    entry_metadata = Map.merge(entry_metadata, metadata)

    # Write to site log
    case Store.write(data.site_log_pid, key, content, entry_metadata) do
      :ok ->
        Logger.debug("#{log_prefix(data.session_id)} Wrote to site log: #{category} -> #{key}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{log_prefix(data.session_id)} Failed to write to site log: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp generate_site_log_key(category, metadata) do
    # Check if an explicit key is provided (e.g., for :plan entries)
    case Map.get(metadata, :key) do
      nil ->
        # No explicit key - generate based on category and metadata
        generate_stable_or_unique_key(category, metadata)

      explicit_key ->
        # Use explicit key without timestamp (allows overwrites)
        "#{category}-#{explicit_key}"
    end
  end

  # Semantic categories use stable keys to allow overwrites (spec section 5.4)
  defp generate_stable_or_unique_key(category, metadata)
       when category in [:contract, :decision, :complete, :failed] do
    # Use deliverable_name if available, otherwise lead_id
    base_key =
      Map.get(metadata, :deliverable_name) ||
        Map.get(metadata, :deliverable) ||
        Map.get(metadata, :lead_id, "entry")

    "#{category}-#{base_key}"
  end

  # Other categories use unique keys with timestamps
  defp generate_stable_or_unique_key(category, metadata) do
    timestamp = System.system_time(:millisecond)
    base_key = Map.get(metadata, :lead_id, "entry")
    "#{category}-#{base_key}-#{timestamp}"
  end

  defp check_phase_transition(:complete, :executing, data) do
    # Check if all leads are complete and merged
    if all_leads_complete?(data) do
      Logger.info(
        "#{log_prefix(data.session_id)} All Leads complete, transitioning to verification phase"
      )

      {:transition, :verifying}
    else
      :no_transition
    end
  end

  defp check_phase_transition(_type, _phase, _data) do
    :no_transition
  end

  # Check if all Leads have completed and been merged
  defp all_leads_complete?(data) do
    # All Leads complete if:
    # 1. We have a plan with deliverables
    # 2. All deliverables have been started
    # 3. All started deliverables have a corresponding completion OR failure record in the site log
    # 4. No Leads remain in the tracking map (all merged and cleaned up)
    has_plan = not is_nil(data.plan) and not is_nil(Map.get(data.plan, :deliverables))

    if has_plan do
      deliverables_count = length(Map.get(data.plan, :deliverables, []))
      started_count = MapSet.size(data.started_leads)
      remaining_leads = map_size(data.leads)

      # Get completed and failed deliverables from site log
      completed_deliverables = determine_completed_deliverables(data)
      completed_count = length(completed_deliverables)

      failed_deliverables = determine_failed_deliverables(data)
      failed_count = length(failed_deliverables)

      finished_count = completed_count + failed_count

      # All deliverables started, all started deliverables finished (completed or failed), and no Leads remain
      deliverables_count > 0 and started_count == deliverables_count and
        finished_count == deliverables_count and remaining_leads == 0
    else
      false
    end
  end

  defp generate_message_id do
    "msg_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
  end

  # Runs post-merge tests on the job branch using the configured test command.
  # This catches semantic conflicts that may not show up as merge conflicts.

  # Cleans up a Lead's worktree when the Lead crashes.
  # Uses `git worktree remove --force` to handle cases where index.lock exists.
  defp cleanup_worktree(worktree_path, working_dir, session_id) do
    # Change to working directory to ensure git command operates in correct repo
    File.cd!(working_dir, fn ->
      # Use --force to remove worktree even if index.lock exists
      {output, exit_code} = Git.cmd(["worktree", "remove", "--force", worktree_path])

      case exit_code do
        0 ->
          Logger.info("#{log_prefix(session_id)} Successfully removed worktree: #{worktree_path}")
          :ok

        _ ->
          Logger.error(
            "#{log_prefix(session_id)} Failed to remove worktree #{worktree_path}: #{output}"
          )

          {:error, output}
      end
    end)
  end

  defp delete_lead_branch(lead_id, working_dir, session_id) do
    branch_name = "deft/lead-#{lead_id}"

    File.cd!(working_dir, fn ->
      {output, exit_code} = Git.cmd(["branch", "-D", branch_name])

      case exit_code do
        0 ->
          Logger.info(
            "#{log_prefix(session_id)} Successfully deleted Lead branch: #{branch_name}"
          )

          :ok

        _ ->
          Logger.error(
            "#{log_prefix(session_id)} Failed to delete Lead branch #{branch_name}: #{output}"
          )

          {:error, output}
      end
    end)
  end

  # Cleans up all remaining Lead worktrees on job completion, failure, or abort.
  # Iterates through all Leads tracked in data.leads and removes their worktrees.
  defp cleanup_all_lead_worktrees(data) do
    if map_size(data.leads) == 0 do
      Logger.debug("#{log_prefix(data.session_id)} No Lead worktrees to clean up")
    else
      Logger.info(
        "#{log_prefix(data.session_id)} Cleaning up #{map_size(data.leads)} Lead worktree(s)"
      )

      Enum.each(data.leads, fn {lead_id, lead_info} ->
        worktree_path = lead_info.worktree_path

        Logger.info(
          "#{log_prefix(data.session_id)} Cleaning up worktree for Lead #{lead_id}: #{worktree_path}"
        )

        cleanup_worktree(worktree_path, data.working_dir, data.session_id)
      end)

      Logger.info("#{log_prefix(data.session_id)} All Lead worktrees cleaned up")
    end

    :ok
  end

  # Deletes the job branch on abort or verification failure.
  # Only called when job_keep_failed_branches config is false.
  defp delete_job_branch_on_failure(job_id, working_dir) do
    job_branch = "deft/job-#{job_id}"

    File.cd!(working_dir, fn ->
      case Git.cmd(["branch", "-D", job_branch]) do
        {_output, 0} ->
          Logger.info("#{log_prefix(job_id)} Deleted job branch: #{job_branch}")
          :ok

        {error_output, _exit_code} ->
          # Log warning but don't fail - branch deletion is non-fatal
          Logger.warning(
            "#{log_prefix(job_id)} Failed to delete job branch #{job_branch}: #{error_output}"
          )

          :ok
      end
    end)
  end

  # Archives job files for debugging by writing a status file.
  # Job files remain at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/
  # but are marked with their completion status for later reference.
  defp archive_job_files(job_id, working_dir, status) do
    jobs_dir = Project.jobs_dir(working_dir)
    job_dir = Path.join(jobs_dir, job_id)

    # Create a status file to mark this job as archived
    status_file = Path.join(job_dir, "status.txt")

    status_content = """
    Job Status: #{status}
    Archived At: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    Job ID: #{job_id}
    """

    case File.write(status_file, status_content) do
      :ok ->
        Logger.info(
          "#{log_prefix(job_id)} Archived job files for job #{job_id} with status: #{status}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "#{log_prefix(job_id)} Failed to write status file for job #{job_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Determine research tasks based on the prompt
  # In real implementation, the Foreman would analyze the prompt to determine what research is needed
  # For now, return a default set of research tasks
  defp determine_research_tasks(prompt) do
    [
      %{
        instructions: """
        Analyze the codebase structure and identify key files and directories.
        Focus on understanding the overall architecture.
        """,
        context: "User request: #{prompt}"
      },
      %{
        instructions: """
        Identify existing patterns, conventions, and technologies used in the codebase.
        Look for configuration files, dependencies, and framework choices.
        """,
        context: "User request: #{prompt}"
      }
    ]
  end

  # Get provider module from config
  defp get_provider(data) do
    # Allow tests to inject a provider module directly via config
    case Map.get(data.config, :provider_module) do
      nil ->
        provider_value = Map.get(data.config, :provider, "anthropic")
        # Normalize provider to string (CLI sets it as atom, Registry expects string)
        provider_name = normalize_provider_name(provider_value)
        # Use Foreman's model for resolving provider
        model_name = Map.get(data.config, :job_foreman_model, "claude-sonnet-4-20250514")

        case Deft.Provider.Registry.resolve(provider_name, model_name) do
          {:ok, {provider_module, _model_config}} ->
            provider_module

          {:error, _} ->
            # Fallback to anthropic
            {:ok, {provider_module, _}} =
              Deft.Provider.Registry.resolve("anthropic", "claude-sonnet-4-20250514")

            provider_module
        end

      module ->
        module
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

  # Determine the next phase after completing current agent loop
  # Returns {next_state, updated_data}
  defp determine_next_phase(:planning, data) do
    # After planning completes, extract research tasks from the LLM response
    # and transition to researching
    research_task_specs = extract_research_tasks_from_messages(data.messages, data.session_id)

    # Store the research task specs in data for use in researching phase
    # If extraction failed, research_task_specs will be nil and researching phase will use defaults
    updated_data = Map.put(data, :research_task_specs, research_task_specs)

    {{:researching, :idle}, updated_data}
  end

  defp determine_next_phase(:decomposing, data) do
    # After decomposition completes, extract plan and wait for approval
    # The plan should be in the last assistant message
    plan = extract_plan_from_messages(data.messages, data.session_id)

    if plan do
      # Write plan to site log
      write_plan_to_site_log(plan, data)

      # Check if auto-approve is enabled
      auto_approve = Map.get(data.config, :auto_approve_all, false)

      if auto_approve do
        Logger.info(
          "#{log_prefix(data.session_id)} Auto-approving plan (--auto-approve-all enabled)"
        )

        # Store plan and transition directly to executing
        updated_data = store_plan_and_build_dependencies(plan, data)
        {{:executing, :idle}, updated_data}
      else
        # Present plan to user and stay in decomposing until approved
        present_plan_for_approval(plan, data)
        # Store plan for when user approves
        updated_data = %{data | plan: plan}
        # Stay in decomposing:idle waiting for user approval
        {{:decomposing, :idle}, updated_data}
      end
    else
      # No valid plan extracted, stay in decomposing
      Logger.warning(
        "#{log_prefix(data.session_id)} Failed to extract plan from decomposition response"
      )

      {{:decomposing, :idle}, data}
    end
  end

  defp determine_next_phase(job_phase, data) do
    # For other phases, stay in idle within the same phase
    {{job_phase, :idle}, data}
  end

  # Build decomposition prompt with research findings
  defp build_planning_prompt(user_prompt) do
    """
    You are the Foreman for a software development job. Your first task is to analyze the user's request
    and determine what research is needed before decomposing the work into deliverables.

    # User Request

    #{user_prompt}

    # Your Task

    Analyze this request and determine what research tasks are needed to gather the information necessary
    for planning the implementation. Each research task will be executed by a research Runner with read-only
    tools (Read, Grep, Find, Ls) that can explore the codebase.

    Produce a list of 1-5 research tasks. For each task, provide:

    1. **Instructions**: Clear, detailed instructions for the research Runner about what to investigate.
       Be specific about what files to read, what patterns to grep for, or what directories to explore.

    2. **Context**: Why this research is needed and what questions it should answer.

    Format your response as a JSON array of research tasks:

    ```json
    [
      {
        "instructions": "Detailed instructions for the research Runner...",
        "context": "Why this research is needed..."
      },
      ...
    ]
    ```

    Think carefully about:
    - What information is needed to understand the existing codebase structure
    - What patterns, conventions, and technologies need to be identified
    - What dependencies or interfaces need to be understood
    - Keep research focused and actionable (each task should take < 2 minutes)
    """
  end

  defp build_decomposition_prompt(data) do
    # Format research findings
    findings_text =
      if Enum.empty?(data.research_findings) do
        "No research findings available."
      else
        data.research_findings
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {finding, idx} ->
          "## Research Finding #{idx}\n\n#{finding}"
        end)
      end

    """
    You are the Foreman for a software development job. Based on the user request and research findings,
    decompose this work into deliverables.

    # Original User Request

    #{data.prompt}

    # Research Findings

    #{findings_text}

    # Your Task

    Produce a structured work plan with:

    1. **Deliverables** (typically 1-3, rarely >5): Each deliverable is a coherent chunk of work that a Lead can own end-to-end.
       For each deliverable, provide:
       - Name (short, descriptive)
       - Description (what needs to be built)
       - Files likely to be modified/created
       - Estimated complexity (low/medium/high)

    2. **Dependency DAG**: Define dependencies between deliverables using their names.
       Format as: "DeliverableA depends_on DeliverableB"

    3. **Interface Contracts**: For each dependency edge, define what the upstream deliverable must provide.
       This allows partial unblocking - the downstream deliverable can start as soon as the contract is satisfied.
       Format as: "DeliverableA needs from DeliverableB: <specific interface details>"

    4. **Cost & Duration Estimate**: Rough estimate of total implementation time and API cost.

    Format your response as a structured JSON plan or use clear markdown sections.

    Think carefully about:
    - Natural decomposition boundaries (avoid artificial splits)
    - Minimal dependencies (more parallelism = faster)
    - Clear interfaces (enables partial unblocking)
    - Single-agent fallback (if task is simple enough, recommend executing directly)
    """
  end

  # Extract research tasks from the last assistant message
  # Returns a list of research task specs, or nil if parsing fails
  defp extract_research_tasks_from_messages(messages, session_id) do
    # Get the last assistant message
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :assistant)) do
      nil ->
        nil

      message ->
        # Extract text content from message
        text_content =
          message.content
          |> Enum.filter(&match?(%Deft.Message.Text{}, &1))
          |> Enum.map(& &1.text)
          |> Enum.join("\n")

        # Try to extract JSON array of research tasks
        case parse_research_tasks_json(text_content) do
          {:ok, tasks} when is_list(tasks) and length(tasks) > 0 ->
            tasks

          _ ->
            Logger.warning(
              "#{log_prefix(session_id)} Failed to parse research tasks from planning response, using defaults"
            )

            nil
        end
    end
  end

  # Parse research tasks from JSON format
  # Expects an array of {"instructions": "...", "context": "..."}
  defp parse_research_tasks_json(text) do
    # Extract JSON from code blocks if present
    json_text =
      case Regex.run(~r/```(?:json)?\s*\n(.*?)\n```/s, text) do
        [_, json] -> json
        nil -> text
      end

    case Jason.decode(json_text) do
      {:ok, tasks} when is_list(tasks) ->
        # Validate and transform each task
        parsed_tasks =
          Enum.map(tasks, fn task ->
            %{
              instructions: Map.get(task, "instructions", ""),
              context: Map.get(task, "context", "")
            }
          end)
          |> Enum.filter(fn %{instructions: inst} -> inst != "" end)

        if Enum.empty?(parsed_tasks) do
          :error
        else
          {:ok, parsed_tasks}
        end

      _ ->
        :error
    end
  end

  # Extract plan from the last assistant message
  # Returns a map with deliverables, dag, contracts, and estimates
  # Returns nil if no valid plan found
  defp extract_plan_from_messages(messages, session_id) do
    # Get the last assistant message
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :assistant)) do
      nil ->
        nil

      message ->
        # Extract text content from message
        text_content =
          message.content
          |> Enum.filter(&match?(%Deft.Message.Text{}, &1))
          |> Enum.map(& &1.text)
          |> Enum.join("\n")

        # Try to parse as JSON first, then fall back to markdown
        case parse_json_plan(text_content) do
          {:ok, plan} ->
            Map.put(plan, :raw_plan, text_content)

          :error ->
            case parse_markdown_plan(text_content) do
              {:ok, plan} ->
                Map.put(plan, :raw_plan, text_content)

              :error ->
                Logger.warning("#{log_prefix(session_id)} Failed to parse plan from response")
                nil
            end
        end
    end
  end

  # Parse plan from JSON format
  # Expects {"deliverables": [...], "dependencies": [...], "contracts": [...], "estimates": {...}}
  defp parse_json_plan(text) do
    # Extract JSON from code blocks if present
    json_text =
      case Regex.run(~r/```(?:json)?\s*\n(.*?)\n```/s, text) do
        [_, json] -> json
        nil -> text
      end

    case Jason.decode(json_text) do
      {:ok, data} ->
        deliverables = parse_deliverables(data["deliverables"] || [])
        dependencies = parse_dependencies(data["dependencies"] || [])
        contracts = parse_contracts(data["contracts"] || [])
        estimates = parse_estimates(data["estimates"] || %{})

        {:ok,
         %{
           deliverables: deliverables,
           dependencies: dependencies,
           contracts: contracts,
           estimates: estimates
         }}

      {:error, _} ->
        :error
    end
  end

  # Parse plan from markdown format
  # Looks for ## Deliverables, ## Dependencies, ## Contracts, ## Estimates sections
  defp parse_markdown_plan(text) do
    deliverables = extract_markdown_deliverables(text)
    dependencies = extract_markdown_dependencies(text)
    contracts = extract_markdown_contracts(text)
    estimates = extract_markdown_estimates(text)

    # Consider valid if we found at least some deliverables
    if Enum.empty?(deliverables) do
      :error
    else
      {:ok,
       %{
         deliverables: deliverables,
         dependencies: dependencies,
         contracts: contracts,
         estimates: estimates
       }}
    end
  end

  # Parse deliverables from JSON data
  defp parse_deliverables(deliverables) when is_list(deliverables) do
    Enum.map(deliverables, fn d ->
      %{
        name: d["name"] || "Unnamed",
        description: d["description"] || "",
        files: d["files"] || [],
        complexity: d["complexity"] || "medium"
      }
    end)
  end

  defp parse_deliverables(_), do: []

  # Parse dependencies from JSON data
  defp parse_dependencies(dependencies) when is_list(dependencies) do
    dependencies
  end

  defp parse_dependencies(_), do: []

  # Parse contracts from JSON data
  defp parse_contracts(contracts) when is_list(contracts) do
    contracts
  end

  defp parse_contracts(_), do: []

  # Parse estimates from JSON data
  defp parse_estimates(estimates) when is_map(estimates) do
    %{
      duration: estimates["duration"] || "unknown",
      cost: estimates["cost"] || "unknown"
    }
  end

  defp parse_estimates(_), do: %{duration: "unknown", cost: "unknown"}

  # Extract deliverables from markdown sections
  defp extract_markdown_deliverables(text) do
    # Look for ## Deliverables or ## 1. Deliverables section
    case Regex.run(~r/##\s*(?:\d+\.)?\s*Deliverables?\s*\n(.*?)(?=\n##|\z)/s, text) do
      [_, section] ->
        # Parse each deliverable (looking for **Name:** or ### Name patterns)
        section
        |> String.split(~r/\n(?=[-*]\s+\*\*|\n###)/)
        |> Enum.map(&parse_markdown_deliverable/1)
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  # Parse a single deliverable from markdown
  defp parse_markdown_deliverable(text) do
    case extract_deliverable_name(text) do
      nil ->
        nil

      name ->
        %{
          name: name,
          description: extract_deliverable_description(text),
          files: extract_deliverable_files(text),
          complexity: extract_deliverable_complexity(text)
        }
    end
  end

  # Extract deliverable name from various markdown patterns
  defp extract_deliverable_name(text) do
    Regex.run(~r/\*\*Name:\*\*\s*(.+?)(?:\n|$)/, text) ||
      Regex.run(~r/###\s+(.+?)(?:\n|$)/, text) ||
      Regex.run(~r/[-*]\s+\*\*(.+?)\*\*/, text)
      |> case do
        [_, n] -> String.trim(n)
        nil -> nil
      end
  end

  # Extract deliverable description
  defp extract_deliverable_description(text) do
    case Regex.run(~r/\*\*Description:\*\*\s*(.+?)(?=\n\*\*|\z)/s, text) do
      [_, desc] ->
        String.trim(desc)

      nil ->
        text
        |> String.replace(~r/\*\*[^*]+:\*\*/, "")
        |> String.trim()
    end
  end

  # Extract deliverable files
  defp extract_deliverable_files(text) do
    case Regex.run(~r/\*\*Files:\*\*\s*(.+?)(?=\n\*\*|\n##|\z)/s, text) do
      [_, files_text] ->
        files_text
        |> String.split(~r/[,\n]/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  # Extract deliverable complexity
  defp extract_deliverable_complexity(text) do
    case Regex.run(~r/\*\*Complexity:\*\*\s*(\w+)/, text) do
      [_, c] -> String.downcase(c)
      nil -> "medium"
    end
  end

  # Extract dependencies from markdown
  defp extract_markdown_dependencies(text) do
    case Regex.run(
           ~r/##\s*(?:\d+\.)?\s*Dependenc(?:y|ies)\s*(?:DAG)?\s*\n(.*?)(?=\n##|\z)/s,
           text
         ) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.contains?(&1, "depends_on"))
        |> Enum.map(&extract_dependency_spec/1)
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  # Extract a dependency spec from a line
  defp extract_dependency_spec(line) do
    # Match patterns like "A depends_on B" or "- A depends_on B"
    case Regex.run(~r/[-*]?\s*(.+?)\s+depends_on\s+(.+?)(?:\s|$)/, line) do
      [_, dependent, dependency] ->
        "#{String.trim(dependent)} depends_on #{String.trim(dependency)}"

      nil ->
        nil
    end
  end

  # Extract contracts from markdown
  defp extract_markdown_contracts(text) do
    case Regex.run(
           ~r/##\s*(?:\d+\.)?\s*(?:Interface\s+)?Contracts?\s*\n(.*?)(?=\n##|\z)/s,
           text
         ) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.contains?(&1, "needs from"))
        |> Enum.map(&extract_contract_spec/1)
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  # Extract a contract spec from a line
  defp extract_contract_spec(line) do
    # Match patterns like "A needs from B: description" or "- A needs from B: description"
    case Regex.run(~r/[-*]?\s*(.+?)\s+needs from\s+(.+?):\s*(.+?)(?:\s|$)/s, line) do
      [_, dependent, dependency, desc] ->
        "#{String.trim(dependent)} needs from #{String.trim(dependency)}: #{String.trim(desc)}"

      nil ->
        nil
    end
  end

  # Extract estimates from markdown
  defp extract_markdown_estimates(text) do
    duration =
      case Regex.run(~r/\*\*(?:Duration|Time):\*\*\s*(.+?)(?:\n|$)/, text) do
        [_, d] -> String.trim(d)
        nil -> "unknown"
      end

    cost =
      case Regex.run(~r/\*\*Cost:\*\*\s*(.+?)(?:\n|$)/, text) do
        [_, c] -> String.trim(c)
        nil -> "unknown"
      end

    %{duration: duration, cost: cost}
  end

  # Write plan to site log
  defp write_plan_to_site_log(plan, data) do
    # Write the plan as a JSON file in the job directory
    jobs_dir = Project.jobs_dir(data.working_dir)
    plan_path = Path.join([jobs_dir, data.session_id, "plan.json"])

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(plan_path))

    # Write plan to file
    case Jason.encode(plan, pretty: true) do
      {:ok, json} ->
        File.write!(plan_path, json)
        Logger.info("#{log_prefix(data.session_id)} Wrote plan to #{plan_path}")

        # Also write to site log
        write_to_site_log(:plan, Jason.encode!(plan), %{key: "work-plan"}, data)

      {:error, reason} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Failed to encode plan as JSON: #{inspect(reason)}"
        )
    end
  end

  # Present plan to user for approval
  defp present_plan_for_approval(plan, data) do
    # Send plan to CLI process if available
    if data.cli_pid && Process.alive?(data.cli_pid) do
      send(data.cli_pid, {:plan_approval_needed, plan})
    else
      # Fallback for interactive sessions or when no CLI is attached
      Logger.info("#{log_prefix(data.session_id)} Plan ready for approval:\n#{plan.raw_plan}")

      Logger.info(
        "#{log_prefix(data.session_id)} Waiting for user approval (send {:approve_plan} or {:reject_plan} message)"
      )
    end
  end

  # Store the plan and build dependency tracking structures
  defp store_plan_and_build_dependencies(plan, data) do
    # Parse dependencies to build blocked_leads map
    # Dependencies format: ["DeliverableA depends_on DeliverableB"]
    # Contracts format: ["DeliverableA needs from DeliverableB: description"]

    # Build a map of deliverable => list of contracts it needs
    contracts = plan.contracts || []

    blocked_leads =
      contracts
      |> Enum.reduce(%{}, fn contract_spec, acc ->
        case parse_contract_spec(contract_spec) do
          {:ok, dependent, dependency, _contract_desc} ->
            # Add this contract requirement to the dependent's needs
            Map.update(acc, dependent, [dependency], fn existing ->
              [dependency | existing]
            end)

          :error ->
            Logger.warning(
              "#{log_prefix(data.session_id)} Failed to parse contract spec: #{contract_spec}"
            )

            acc
        end
      end)

    Logger.info(
      "#{log_prefix(data.session_id)} Built dependency tracking: #{inspect(blocked_leads)}"
    )

    %{data | plan: plan, blocked_leads: blocked_leads, started_leads: MapSet.new()}
  end

  # Parse a contract spec like "API needs from Database: User schema"
  # Returns {:ok, dependent, dependency, contract_description} or :error
  defp parse_contract_spec(contract_spec) do
    # Pattern: "<Dependent> needs from <Dependency>: <description>"
    case Regex.run(~r/^(.+?)\s+needs from\s+(.+?):\s*(.+)$/, contract_spec) do
      [_full, dependent, dependency, description] ->
        {:ok, String.trim(dependent), String.trim(dependency), String.trim(description)}

      _ ->
        :error
    end
  end

  # Get deliverables that are ready to start (no unmet dependencies)
  defp get_ready_deliverables(data) do
    if is_nil(data.plan) or is_nil(data.plan.deliverables) do
      []
    else
      data.plan.deliverables
      |> Enum.filter(fn deliverable ->
        # Ready if not already started and not in blocked_leads
        not MapSet.member?(data.started_leads, deliverable.name) and
          not Map.has_key?(data.blocked_leads, deliverable.name)
      end)
    end
  end

  # Start a Lead for the given deliverable
  defp start_lead(deliverable, data) do
    lead_id = "#{data.session_id}-#{deliverable.name}"

    Logger.info(
      "#{log_prefix(data.session_id)} Starting Lead for deliverable: #{deliverable.name} (#{lead_id})"
    )

    # Create worktree for this Lead
    case GitJob.create_lead_worktree(
           lead_id: lead_id,
           job_id: data.session_id,
           working_dir: data.working_dir
         ) do
      {:ok, worktree_path} ->
        # Get site log name
        site_log_name = {:sitelog, data.session_id}

        # RunnerSupervisor name for reference (created by Lead.Supervisor)
        runner_supervisor_name =
          {:via, Registry, {Deft.ProcessRegistry, {:runner_supervisor, lead_id}}}

        # Start Lead.Supervisor which will manage both the Lead gen_statem
        # and its RunnerSupervisor as siblings
        lead_opts = [
          lead_id: lead_id,
          session_id: data.session_id,
          config: data.config,
          deliverable: deliverable.description,
          foreman_pid: self(),
          site_log_name: site_log_name,
          rate_limiter_pid: data.rate_limiter_pid,
          worktree_path: worktree_path,
          working_dir: data.working_dir
        ]

        case LeadSupervisor.start_lead(data.session_id, lead_opts) do
          {:ok, lead_pid} ->
            # Monitor the Lead process
            monitor_ref = Process.monitor(lead_pid)

            lead_info = %{
              deliverable: deliverable,
              worktree_path: worktree_path,
              status: :running,
              pid: lead_pid,
              monitor_ref: monitor_ref,
              runner_supervisor: runner_supervisor_name,
              agent_state: :implementing
            }

            leads = Map.put(data.leads, lead_id, lead_info)
            started_leads = MapSet.put(data.started_leads, deliverable.name)

            Logger.info(
              "#{log_prefix(data.session_id)} Lead #{lead_id} started with PID #{inspect(lead_pid)} and worktree at #{worktree_path}"
            )

            %{data | leads: leads, started_leads: started_leads}

          {:error, reason} ->
            Logger.error(
              "#{log_prefix(data.session_id)} Failed to start Lead #{lead_id}: #{inspect(reason)}"
            )

            # Write failure marker to site log to allow completion check to be satisfied
            write_failure_marker(
              lead_id,
              deliverable.name,
              "Failed to start Lead: #{inspect(reason)}",
              data
            )

            # Clean up the worktree that was created
            cleanup_worktree(worktree_path, data.working_dir, data.session_id)

            # Add to started_leads so all_leads_complete? can eventually be satisfied
            started_leads = MapSet.put(data.started_leads, deliverable.name)
            %{data | started_leads: started_leads}
        end

      {:error, reason} ->
        Logger.error(
          "#{log_prefix(data.session_id)} Failed to create worktree for Lead #{lead_id}: #{inspect(reason)}"
        )

        # Write failure marker to site log to allow completion check to be satisfied
        write_failure_marker(
          lead_id,
          deliverable.name,
          "Failed to create worktree: #{inspect(reason)}",
          data
        )

        # Add to started_leads so all_leads_complete? can eventually be satisfied
        started_leads = MapSet.put(data.started_leads, deliverable.name)
        %{data | started_leads: started_leads}
    end
  end

  # Check if a published contract satisfies a dependency need
  defp contract_matches?(needed_contract, publishing_deliverable, _contract_content) do
    # Check if the publishing deliverable matches the needed dependency
    # A contract from the required deliverable satisfies the dependency
    # Future enhancement: parse contract_content to verify it meets specific interface requirements
    publishing_deliverable != nil and publishing_deliverable == needed_contract
  end

  # Check if a deliverable depends on a contract from another deliverable
  defp lead_depends_on_contract?(_deliverable, nil, _plan), do: false
  defp lead_depends_on_contract?(_deliverable, _publishing_deliverable, nil), do: false

  defp lead_depends_on_contract?(deliverable, publishing_deliverable, plan) do
    # Get the deliverable name (handle both struct and map)
    deliverable_name =
      case deliverable do
        %{name: name} -> name
        name when is_binary(name) -> name
        _ -> nil
      end

    # Check if this deliverable has contracts from the publishing deliverable
    contracts = Map.get(plan, :contracts, [])

    # Look through contracts to see if this deliverable needs something from publishing_deliverable
    Enum.any?(contracts, fn contract_spec ->
      case parse_contract_spec(contract_spec) do
        {:ok, dependent, dependency, _desc} ->
          # Check if this deliverable is the dependent and the publishing deliverable is the dependency
          deliverable_name == dependent and publishing_deliverable == dependency

        :error ->
          false
      end
    end)
  end

  # Detect conflicts between a new decision and existing decisions from other Leads
  defp detect_decision_conflicts(new_decision, existing_decisions, leads) do
    # Only compare with decisions from other Leads that are still running
    active_lead_ids = leads |> Map.keys() |> MapSet.new()

    # Filter to decisions from other active Leads made in the last 5 minutes
    cutoff_time = DateTime.add(DateTime.utc_now(), -300, :second)

    recent_decisions =
      existing_decisions
      |> Enum.filter(fn d ->
        d.lead_id != new_decision.lead_id and
          d.lead_id in active_lead_ids and
          DateTime.compare(d.timestamp, cutoff_time) == :gt
      end)

    # Check for conflicts using heuristics
    Enum.filter(recent_decisions, fn existing_decision ->
      decisions_conflict?(new_decision, existing_decision)
    end)
  end

  # Determine if two decisions conflict
  defp decisions_conflict?(decision1, decision2) do
    content1 = String.downcase(decision1.content)
    content2 = String.downcase(decision2.content)

    # Extract file paths from both decisions
    files1 = extract_file_paths(content1)
    files2 = extract_file_paths(content2)

    # Check if they mention the same files
    file_overlap = MapSet.intersection(files1, files2) |> MapSet.size() > 0

    # Check for contradictory keywords
    contradictory = has_contradictory_keywords?(content1, content2)

    file_overlap or contradictory
  end

  # Extract file paths from decision content
  defp extract_file_paths(content) do
    # Match common file path patterns: lib/foo/bar.ex, src/file.js, etc.
    ~r/\b\w+\/[\w\/]+\.\w+\b/
    |> Regex.scan(content)
    |> Enum.map(fn [match] -> match end)
    |> MapSet.new()
  end

  # Check for contradictory keywords between two decision contents
  defp has_contradictory_keywords?(content1, content2) do
    # Extract libraries/technologies mentioned with action verbs
    use_in_1 = extract_keywords(content1, ~r/\buse\s+(\w+)/i)
    use_in_2 = extract_keywords(content2, ~r/\buse\s+(\w+)/i)
    avoid_in_1 = extract_keywords(content1, ~r/\bavoid\s+(\w+)/i)
    avoid_in_2 = extract_keywords(content2, ~r/\bavoid\s+(\w+)/i)
    not_use_in_1 = extract_keywords(content1, ~r/\bnot\s+use\s+(\w+)/i)
    not_use_in_2 = extract_keywords(content2, ~r/\bnot\s+use\s+(\w+)/i)

    # Check if one Lead wants to use something the other wants to avoid
    use_avoid_conflict =
      not MapSet.disjoint?(use_in_1, avoid_in_2) or
        not MapSet.disjoint?(use_in_2, avoid_in_1) or
        not MapSet.disjoint?(use_in_1, not_use_in_2) or
        not MapSet.disjoint?(use_in_2, not_use_in_1)

    # Check for add/remove conflicts
    add_in_1 = extract_keywords(content1, ~r/\badd\s+(\w+)/i)
    add_in_2 = extract_keywords(content2, ~r/\badd\s+(\w+)/i)
    remove_in_1 = extract_keywords(content1, ~r/\bremove\s+(\w+)/i)
    remove_in_2 = extract_keywords(content2, ~r/\bremove\s+(\w+)/i)

    add_remove_conflict =
      not MapSet.disjoint?(add_in_1, remove_in_2) or
        not MapSet.disjoint?(add_in_2, remove_in_1)

    use_avoid_conflict or add_remove_conflict
  end

  # Extract keywords from content using a regex pattern with one capture group
  defp extract_keywords(content, pattern) do
    pattern
    |> Regex.scan(content)
    |> Enum.map(fn [_full, keyword] -> String.downcase(keyword) end)
    |> MapSet.new()
  end

  # Pause affected Leads by updating their status and sending steering messages
  defp pause_leads(lead_ids, data) do
    Enum.reduce(lead_ids, data, fn lead_id, acc_data ->
      case Map.get(acc_data.leads, lead_id) do
        nil ->
          Logger.warning(
            "#{log_prefix(data.session_id)} Cannot pause Lead #{lead_id} - not found"
          )

          acc_data

        lead_info ->
          # Update Lead status to paused
          updated_lead_info = %{lead_info | status: :paused}
          updated_leads = Map.put(acc_data.leads, lead_id, updated_lead_info)

          # Send steering message to pause the Lead
          send(lead_info.pid, {:foreman_steering, build_pause_message()})

          Logger.info(
            "#{log_prefix(data.session_id)} Paused Lead #{lead_id} due to decision conflict"
          )

          %{acc_data | leads: updated_leads}
      end
    end)
  end

  # Build a pause message for steering
  defp build_pause_message do
    """
    DECISION CONFLICT DETECTED

    Your recent decision conflicts with a decision from another parallel Lead.
    Please pause your work while the Foreman resolves this conflict.

    You will receive further instructions shortly.
    """
  end

  # Resolve a decision conflict or escalate to user
  defp resolve_conflict(new_decision, conflicting_decisions, affected_lead_ids, data) do
    # For now, log the conflict details and escalate to user
    # In a future enhancement, this could use an LLM to attempt automatic resolution

    conflict_summary =
      build_conflict_summary(new_decision, conflicting_decisions, affected_lead_ids)

    Logger.warning(
      "#{log_prefix(data.session_id)} Decision conflict requiring resolution:\n#{conflict_summary}"
    )

    # Store conflict for user to review
    # For MVP, send steering to affected Leads asking them to coordinate
    Enum.each(affected_lead_ids, fn lead_id ->
      case Map.get(data.leads, lead_id) do
        nil ->
          :ok

        lead_info ->
          steering_content =
            build_conflict_resolution_message(
              lead_id,
              new_decision,
              conflicting_decisions,
              affected_lead_ids
            )

          send(lead_info.pid, {:foreman_steering, steering_content})
      end
    end)

    data
  end

  # Build a summary of the conflict for logging
  defp build_conflict_summary(new_decision, conflicting_decisions, affected_lead_ids) do
    """
    Affected Leads: #{Enum.join(affected_lead_ids, ", ")}

    New decision from #{new_decision.lead_id}:
    #{new_decision.content}

    Conflicting with:
    #{Enum.map_join(conflicting_decisions, "\n", fn d -> "- #{d.lead_id}: #{d.content}" end)}
    """
  end

  # Build a steering message for conflict resolution
  defp build_conflict_resolution_message(
         lead_id,
         new_decision,
         conflicting_decisions,
         affected_lead_ids
       ) do
    other_leads = Enum.reject(affected_lead_ids, &(&1 == lead_id))

    """
    DECISION CONFLICT RESOLUTION NEEDED

    Your deliverable has a decision that conflicts with decision(s) from parallel Lead(s): #{Enum.join(other_leads, ", ")}

    Your decision:
    #{if(lead_id == new_decision.lead_id, do: new_decision.content, else: "See site log for details")}

    Conflicting decisions:
    #{Enum.map_join(conflicting_decisions, "\n", fn d -> if d.lead_id == lead_id do
        "Your decision: #{d.content}"
      else
        "#{d.lead_id}: #{d.content}"
      end end)}

    #{if lead_id == new_decision.lead_id do
      """

      Since this is a new conflict involving your recent decision, please review the conflicting
      decisions above and either:
      1. Revise your approach to align with the other Lead's decision
      2. Justify why your approach is correct and should take precedence

      Respond with your resolution plan.
      """
    else
      """

      Please review this conflict and coordinate with the other Lead(s). Check the site log
      for full context of all decisions. Respond with your resolution plan.
      """
    end}
    """
  end

  # Verification helpers

  defp analyze_verification_results(results, session_id) do
    # Results from the verification Runner - check for test failures or quality issues
    # The Runner returns {:ok, output} tuple
    case results do
      # Unwrap {:ok, output} tuple from Runner.run
      {:ok, inner_results} ->
        analyze_verification_results(inner_results, session_id)

      %{success: true} ->
        true

      %{success: false} ->
        false

      # If results is a string, check for common failure indicators
      result_str when is_binary(result_str) ->
        # Check for test failure patterns
        not (String.contains?(result_str, "failed") or
               String.contains?(result_str, "error") or
               String.contains?(result_str, "FAILED"))

      # Default to failed if structure is unexpected
      _ ->
        Logger.warning(
          "#{log_prefix(session_id)} Unexpected verification result format: #{inspect(results)}"
        )

        false
    end
  end

  defp identify_responsible_lead(results, data) do
    # Try to map failures to specific Leads based on file paths
    # This is a best-effort attempt - may not always be accurate

    failure_info = extract_failure_info(results)

    # Get file paths mentioned in failures
    failed_files = extract_failed_files(failure_info)

    # Match files to Leads based on their deliverables
    leads_by_files =
      Enum.reduce(data.leads, %{}, fn {lead_id, lead_info}, acc ->
        deliverable = Map.get(lead_info, :deliverable, %{})
        files = Map.get(deliverable, :files, [])
        Map.put(acc, lead_id, files)
      end)

    # Find Lead with most overlap
    lead_scores =
      Enum.map(leads_by_files, fn {lead_id, lead_files} ->
        overlap =
          Enum.count(failed_files, fn failed_file ->
            Enum.any?(lead_files, fn lead_file ->
              String.contains?(failed_file, lead_file) or String.contains?(lead_file, failed_file)
            end)
          end)

        {lead_id, overlap}
      end)

    case Enum.max_by(lead_scores, fn {_id, score} -> score end, fn -> nil end) do
      {lead_id, score} when score > 0 -> lead_id
      _ -> nil
    end
  end

  defp extract_failure_info(results) when is_binary(results), do: results
  defp extract_failure_info(%{message: msg}), do: msg
  defp extract_failure_info(%{error: err}), do: err
  defp extract_failure_info(_), do: ""

  defp extract_failed_files(failure_info) when is_binary(failure_info) do
    # Extract file paths from failure messages
    # Look for common patterns like "path/to/file.ex:123"
    Regex.scan(~r/([a-z_\/]+\.ex):\d+/i, failure_info)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp extract_failed_files(_), do: []

  defp format_verification_failures(results) do
    case results do
      %{message: msg} -> msg
      %{error: err} -> err
      result_str when is_binary(result_str) -> result_str
      _ -> inspect(results)
    end
  end

  defp send_user_message(message, data) do
    # Create an assistant message to add to the session
    assistant_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [%Text{text: message}],
      timestamp: DateTime.utc_now()
    }

    # Add to messages and persist
    messages = data.messages ++ [assistant_message]
    data = %{data | messages: messages}
    data = save_unsaved_messages(data)

    # Send to CLI if available for immediate display during job execution
    if data.cli_pid && Process.alive?(data.cli_pid) do
      send(data.cli_pid, {:job_message, message})
    end

    data
  end

  # Session persistence helpers

  defp save_unsaved_messages(data) do
    alias Deft.Session.{Entry, Store}

    # Find messages that haven't been saved yet
    unsaved_messages =
      Enum.reject(data.messages, fn msg ->
        MapSet.member?(data.saved_message_ids, msg.id)
      end)

    # Save each message to the Foreman session file
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

  # Resume helpers

  defp parse_plan_from_json(plan_data) do
    # Convert JSON plan data back to internal format
    %{
      deliverables: parse_deliverables_from_json(plan_data),
      dependencies: Map.get(plan_data, "dependencies", []),
      contracts: Map.get(plan_data, "contracts", []),
      estimates: parse_estimates_from_json(plan_data),
      raw_plan: Map.get(plan_data, "raw_plan", "")
    }
  end

  defp parse_deliverables_from_json(plan_data) do
    (plan_data["deliverables"] || [])
    |> Enum.map(fn d ->
      %{
        name: Map.get(d, "name", "Unnamed"),
        description: Map.get(d, "description", ""),
        files: Map.get(d, "files", []),
        complexity: Map.get(d, "complexity", "medium")
      }
    end)
  end

  defp parse_estimates_from_json(plan_data) do
    %{
      duration: get_in(plan_data, ["estimates", "duration"]) || "unknown",
      cost: get_in(plan_data, ["estimates", "cost"]) || "unknown"
    }
  end

  defp determine_completed_deliverables(data) do
    # Read the site log to find completed deliverables
    # Deliverables are complete if the site log contains a `:complete` message from their Lead

    # Get all keys from the site log
    tid = Store.tid(data.site_log_pid)
    site_log_keys = Store.keys(tid)

    # Look for "complete-*" entries and extract deliverable names from metadata
    completed_deliverables =
      site_log_keys
      |> Enum.filter(&String.starts_with?(&1, "complete-"))
      |> Enum.map(fn key ->
        # Read the entry to get metadata instead of parsing the key
        case Store.read(tid, key) do
          {:ok, entry} ->
            # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
            lead_id = get_in(entry, [:metadata, :lead_id])

            if lead_id do
              String.replace_prefix(lead_id, "#{data.session_id}-", "")
            else
              nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    completed_deliverables
  end

  defp determine_failed_deliverables(data) do
    # Read the site log to find failed deliverables
    # Deliverables are failed if the site log contains a `:failed` message

    # Get all keys from the site log
    tid = Store.tid(data.site_log_pid)
    site_log_keys = Store.keys(tid)

    # Look for "failed-*" entries and extract deliverable names from metadata
    failed_deliverables =
      site_log_keys
      |> Enum.filter(&String.starts_with?(&1, "failed-"))
      |> Enum.map(fn key ->
        # Read the entry to get metadata instead of parsing the key
        case Store.read(tid, key) do
          {:ok, entry} ->
            # Extract deliverable name from lead_id (format: "#{session_id}-#{deliverable_name}")
            lead_id = get_in(entry, [:metadata, :lead_id])

            if lead_id do
              String.replace_prefix(lead_id, "#{data.session_id}-", "")
            else
              nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    failed_deliverables
  end

  defp write_failure_marker(lead_id, deliverable_name, reason, data) do
    # Write failure marker to site log for resume tracking
    # This allows all_leads_complete? to be satisfied even when Leads crash or fail
    metadata = %{lead_id: lead_id, deliverable: deliverable_name, failure_reason: reason}

    write_to_site_log(
      :failed,
      "Deliverable #{deliverable_name} failed: #{reason}",
      metadata,
      data
    )
  end

  # Job status broadcasting for TUI agent roster

  # Updates the agent_state for a specific Lead in the data.leads map.
  defp update_lead_state(lead_id, new_state, data)
       when is_binary(lead_id) and is_atom(new_state) do
    case Map.get(data.leads, lead_id) do
      nil ->
        Logger.warning(
          "#{log_prefix(data.session_id)} Cannot update state for Lead #{lead_id}: not found in leads map"
        )

        data

      lead_info ->
        updated_lead_info = Map.put(lead_info, :agent_state, new_state)
        updated_leads = Map.put(data.leads, lead_id, updated_lead_info)
        %{data | leads: updated_leads}
    end
  end

  defp update_lead_state(_lead_id, _new_state, data), do: data

  # Builds the agent_statuses list for broadcasting to the TUI.
  # Returns a list of `%{id: String.t(), type: atom(), state: atom(), label: String.t()}`.
  defp build_agent_statuses({job_phase, _agent_state}, data) do
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

  # Maps Foreman job_phase to display state for the TUI.
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

  # Broadcasts job status via Registry for TUI consumption.
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

  # Returns log prefix with first 8 chars of job ID per logging spec §2
  defp log_prefix(session_id) do
    prefix = String.slice(session_id, 0, 8)
    "[Foreman:#{prefix}]"
  end
end
