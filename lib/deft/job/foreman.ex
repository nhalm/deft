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
  alias Deft.Session.Worker, as: SessionWorker
  alias Deft.Store
  alias Deft.Project
  alias Deft.Git
  alias Deft.Git.Job, as: GitJob
  alias Deft.Job.Lead
  alias Deft.Job.Runner
  alias Deft.Job.RateLimiter
  alias Deft.Provider.Anthropic

  require Logger

  # Client API

  @doc """
  Starts the Foreman gen_statem.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:prompt` — Required. Initial user prompt/issue.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:working_dir` — Optional. Working directory for the project (defaults to File.cwd!()).
  - `:name` — Optional. Name for the gen_statem process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    prompt = Keyword.fetch!(opts, :prompt)
    rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    name = Keyword.get(opts, :name)
    resumed_plan = Keyword.get(opts, :resumed_plan)

    # Build session file path for Foreman
    jobs_dir = Project.jobs_dir(working_dir)
    session_file_path = Path.join([jobs_dir, session_id, "foreman_session.jsonl"])

    initial_data = %{
      session_id: session_id,
      config: config,
      prompt: prompt,
      rate_limiter_pid: rate_limiter_pid,
      working_dir: working_dir,
      messages: [],
      leads: %{},
      current_message: nil,
      stream_ref: nil,
      stream_monitor_ref: nil,
      tool_tasks: [],
      tool_call_buffers: %{},
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      session_cost: 0.0,
      research_tasks: [],
      research_findings: [],
      research_timeout_ref: nil,
      site_log_pid: nil,
      plan: resumed_plan,
      blocked_leads: %{},
      started_leads: MapSet.new(),
      cost_ceiling_reached: false,
      decisions: [],
      session_file_path: session_file_path,
      saved_message_ids: MapSet.new()
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

              # Convert plan data to the expected format
              plan = parse_plan_from_json(plan_data)

              # Start Foreman with resume: true flag to trigger resume logic
              start_link(
                session_id: session_id,
                config: Map.put(config, :resume, true),
                prompt: "Resuming job #{session_id}",
                rate_limiter_pid: rate_limiter_pid,
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

    # Build path to site log DETS file
    jobs_dir = Project.jobs_dir(initial_data.working_dir)
    sitelog_path = Path.join([jobs_dir, initial_data.session_id, "sitelog.dets"])

    # Start the site log instance
    {:ok, site_log_pid} =
      Store.start_link(
        name: site_log_name,
        type: :sitelog,
        dets_path: sitelog_path,
        owner_name: foreman_name
      )

    data = %{initial_data | site_log_pid: site_log_pid}

    # Check if we're resuming
    if Map.get(initial_data.config, :resume) && initial_data.plan do
      Logger.info("Resuming job #{initial_data.session_id}")

      # Build dependency structures from the resumed plan
      data = store_plan_and_build_dependencies(initial_data.plan, data)

      # Determine which deliverables are complete by checking site log
      completed_deliverables = determine_completed_deliverables(data)
      Logger.info("Completed deliverables: #{inspect(completed_deliverables)}")

      # Update started_leads to reflect completed work
      started_leads = MapSet.new(completed_deliverables)
      data = %{data | started_leads: started_leads}

      # Start in executing phase, ready to resume incomplete work
      initial_state = {:executing, :idle}
      {:ok, initial_state, data}
    else
      # Normal start in planning phase, idle agent state
      initial_state = {:planning, :idle}
      {:ok, initial_state, data}
    end
  end

  @impl :gen_statem
  # State entry handlers
  def handle_event(:enter, _old_state, {:planning, :idle}, data) do
    # When entering planning phase, send initial prompt as a cast (not next_event)
    # next_event is not allowed in state_enter handlers in newer OTP versions
    :gen_statem.cast(self(), {:prompt, data.prompt})
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {:researching, :idle}, data) do
    # Spawn research Runners in parallel
    Logger.info("Foreman starting research phase")

    # Determine research tasks (placeholder - real implementation would analyze prompt)
    research_specs = determine_research_tasks(data.prompt)

    # Get research timeout from config (default 120s)
    research_timeout = Map.get(data.config, :research_timeout, 120_000)

    # Spawn research Runners via Task.Supervisor.async_nolink
    tasks =
      Enum.map(research_specs, fn %{instructions: instructions, context: context} ->
        task =
          Task.Supervisor.async_nolink(
            SessionWorker.tool_runner_via_tuple(data.session_id),
            fn ->
              # Get research runner model from config (defaults to same as lead model)
              research_model =
                Map.get(data.config, :research_runner_model, Map.get(data.config, :lead_model))

              runner_config = %{
                provider: get_provider(data),
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

    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, {:decomposing, :idle}, _data) do
    # When entering decomposing phase, prompt the Foreman to create a work plan
    Logger.info("Foreman starting decomposition phase")
    :gen_statem.cast(self(), :start_decomposition)
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {:executing, :idle}, _data) do
    # When entering executing phase, start all ready Leads
    Logger.info("Foreman starting execution phase")
    :gen_statem.cast(self(), :start_ready_leads)
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {:verifying, :idle}, _data) do
    # When entering verification phase, spawn verification Runner
    Logger.info("Foreman starting verification phase")
    :gen_statem.cast(self(), :start_verification)
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, {job_phase, :executing_tools}, data) do
    # Extract tool calls from the last assistant message
    tool_calls = extract_tool_calls(data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls - return to idle in current job phase
      {:next_state, {job_phase, :idle}, data}
    else
      # Execute tools
      tasks =
        Enum.map(tool_calls, fn tool_call ->
          Task.Supervisor.async_nolink(
            SessionWorker.tool_runner_via_tuple(data.session_id),
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
    {:ok, stream_ref, monitor_ref} = call_llm(data)
    data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
    {:next_state, {job_phase, :calling}, data}
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
    {:ok, stream_ref, monitor_ref} = call_llm(data)
    data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
    {:next_state, {:decomposing, :calling}, data}
  end

  # Start ready Leads handling
  def handle_event(:cast, :start_ready_leads, {:executing, :idle}, data) do
    # Check if cost ceiling has been reached
    if data.cost_ceiling_reached do
      Logger.info("Cost ceiling reached - not starting new Leads until spending approved")
      {:keep_state_and_data}
    else
      # Determine which Leads can start immediately (no dependencies or dependencies satisfied)
      ready_deliverables = get_ready_deliverables(data)

      # Start each ready Lead
      updated_data =
        Enum.reduce(ready_deliverables, data, fn deliverable, acc_data ->
          start_lead(deliverable, acc_data)
        end)

      {:keep_state, updated_data}
    end
  end

  # Start verification Runner handling
  def handle_event(:cast, :start_verification, {:verifying, :idle}, data) do
    Logger.info("Spawning verification Runner for final testing and review")

    # Get job branch for testing
    job_branch = "deft/job-#{data.session_id}"

    # Get test command from config (defaults to "mix test")
    test_command = Map.get(data.config, :job_test_command, "mix test")

    # Get runner model from config
    runner_model = Map.get(data.config, :runner_model, Map.get(data.config, :lead_model))

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

    runner_config = %{
      provider: get_provider(data),
      model: runner_model
    }

    # Spawn verification Runner
    task =
      Task.Supervisor.async_nolink(
        SessionWorker.tool_runner_via_tuple(data.session_id),
        fn ->
          Runner.run(
            :review,
            verification_instructions,
            verification_context,
            data.session_id,
            runner_config,
            data.working_dir
          )
        end
      )

    # Store verification task
    {:keep_state, %{data | tool_tasks: [task]}}
  end

  # Abort handling (works in any state)
  def handle_event(:cast, :abort, {_job_phase, _agent_state}, data) do
    Logger.info("Foreman aborting job")
    # Cancel any in-flight streams
    if data.stream_ref do
      cancel_stream(data)
    end

    # Terminate any in-flight tasks
    Enum.each(data.tool_tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    # Clean up all Lead worktrees
    cleanup_all_lead_worktrees(data)

    # Archive job files for debugging
    archive_job_files(data.session_id, data.working_dir, :aborted)

    # Transition to complete phase
    {:next_state, {:complete, :idle},
     %{data | stream_ref: nil, stream_monitor_ref: nil, tool_tasks: []}}
  end

  # Plan approval handling
  def handle_event(:cast, :approve_plan, {:decomposing, :idle}, data) do
    Logger.info("Plan approved by user, transitioning to execution phase")

    # Store plan and build dependency structures if plan exists
    updated_data =
      if data.plan do
        store_plan_and_build_dependencies(data.plan, data)
      else
        Logger.warning("No plan available when approve_plan was called")
        data
      end

    {:next_state, {:executing, :idle}, updated_data}
  end

  def handle_event(:cast, :reject_plan, {:decomposing, :idle}, data) do
    Logger.info("Plan rejected by user, requesting revision")

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
    {:ok, stream_ref, monitor_ref} = call_llm(data)
    data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
    {:next_state, {:decomposing, :calling}, data}
  end

  # Lead message handling (available in any state)
  def handle_event(
        :info,
        {:lead_message, type, content, metadata},
        {job_phase, agent_state},
        data
      ) do
    Logger.info("Foreman received lead message: #{type}")

    # Process the lead message
    data = process_lead_message(type, content, metadata, data)

    # Check if this message triggers a phase transition
    case check_phase_transition(type, job_phase, data) do
      {:transition, new_phase} ->
        {:next_state, {new_phase, agent_state}, data}

      :no_transition ->
        {:keep_state, data}
    end
  end

  # Lead crash handling (DOWN message)
  def handle_event(
        :info,
        {:DOWN, monitor_ref, :process, _pid, reason},
        _state,
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
          "Lead #{lead_id} crashed, cleaning up worktree: #{lead_info.worktree_path}, reason: #{inspect(reason)}"
        )

        # Clean up the Lead's worktree
        cleanup_worktree(lead_info.worktree_path, data.working_dir)

        # Remove crashed Lead from tracking
        leads = Map.delete(leads, lead_id)
        data = %{data | leads: leads}

        # TODO: Decide whether to retry or mark deliverable as failed
        # For now, just clean up and continue

        {:keep_state, data}
    end
  end

  # Rate limiter messages
  def handle_event(:info, {:rate_limiter, :cost, amount}, {_job_phase, _agent_state}, data) do
    Logger.info("Foreman cost checkpoint: $#{amount}")
    # RateLimiter sends cumulative cost, so replace instead of add
    {:keep_state, %{data | session_cost: amount}}
  end

  def handle_event(:info, {:rate_limiter, :cost_warning, cost}, {_job_phase, _agent_state}, _data) do
    Logger.warning("Cost warning reached: $#{Float.round(cost, 2)}")
    # Cost warning is just informational - no state change needed
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:rate_limiter, :concurrency_change, new_limit},
        {_job_phase, _agent_state},
        data
      ) do
    Logger.info("Foreman concurrency change: #{new_limit}")
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
    Logger.warning("Cost ceiling reached: $#{Float.round(cost, 2)} - pausing new Lead spawns")
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
        {:researching, :idle},
        %{research_tasks: tasks} = data
      )
      when is_reference(ref) do
    # A research task completed
    Logger.debug("Research task completed: #{inspect(result)}")

    # Find and remove completed task
    tasks = Enum.reject(tasks, fn task -> task.ref == ref end)

    # Collect findings
    findings =
      case result do
        {:ok, output} ->
          data.research_findings ++ [output]

        {:error, reason} ->
          Logger.warning("Research task failed: #{reason}")
          data.research_findings
      end

    data = %{data | research_tasks: tasks, research_findings: findings}

    # If all research tasks done, transition to decomposing
    if Enum.empty?(tasks) do
      # Cancel timeout timer
      if data.research_timeout_ref do
        Process.cancel_timer(data.research_timeout_ref)
      end

      Logger.info("Research phase complete, collected #{length(findings)} findings")
      {:next_state, {:decomposing, :idle}, data}
    else
      {:keep_state, data}
    end
  end

  # Research timeout
  def handle_event(:info, :research_timeout, {:researching, :idle}, data) do
    Logger.warning(
      "Research timeout reached, proceeding with #{length(data.research_findings)} findings"
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
        {:ok, stream_ref, monitor_ref} = call_llm(data)
        data = %{data | stream_ref: stream_ref, stream_monitor_ref: monitor_ref}
        {:next_state, {job_phase, :calling}, data}
      else
        # Check if we need to transition to next phase
        {next_state, updated_data} = determine_next_phase(job_phase, data)
        {:next_state, next_state, updated_data}
      end
    else
      {:keep_state, data}
    end
  end

  # Verification task completion
  def handle_event(
        :info,
        {ref, results},
        {:verifying, :idle},
        %{tool_tasks: tasks} = data
      )
      when is_reference(ref) do
    # Verification Runner completed
    tasks = Enum.reject(tasks, fn task -> task.ref == ref end)
    data = %{data | tool_tasks: tasks}

    Logger.info("Verification Runner completed")

    # Check verification results
    verification_passed = analyze_verification_results(results)

    if verification_passed do
      Logger.info("Verification passed - proceeding with squash-merge")

      # Get original branch (stored in config or default to current branch)
      original_branch = Map.get(data.config, :original_branch, "main")

      # Trigger squash-merge
      case GitJob.complete_job(
             job_id: data.session_id,
             original_branch: original_branch,
             squash: true,
             working_dir: data.working_dir
           ) do
        {:ok, :completed} ->
          Logger.info("Job completed successfully - squash-merge done")

          # Clean up any remaining Lead worktrees
          cleanup_all_lead_worktrees(data)

          # Archive job files for debugging
          archive_job_files(data.session_id, data.working_dir, :completed)

          {:next_state, {:complete, :idle}, data}

        {:error, reason} ->
          Logger.error("Failed to complete job: #{inspect(reason)}")

          # Clean up any remaining Lead worktrees even on merge failure
          cleanup_all_lead_worktrees(data)

          # Archive job files for debugging
          archive_job_files(data.session_id, data.working_dir, :merge_failed)

          # Report error to user
          error_message = """
          Verification passed but failed to merge changes: #{inspect(reason)}

          You may need to manually merge the job branch: deft/job-#{data.session_id}
          """

          send_user_message(error_message, data)
          {:next_state, {:complete, :idle}, data}
      end
    else
      Logger.warning("Verification failed")

      # Clean up all Lead worktrees
      cleanup_all_lead_worktrees(data)

      # Archive job files for debugging
      archive_job_files(data.session_id, data.working_dir, :verification_failed)

      # Identify responsible Lead based on test failures
      responsible_lead = identify_responsible_lead(results, data)

      # Report failure to user
      failure_message = """
      Verification failed. Test suite or code review found issues.

      #{format_verification_failures(results)}

      #{if responsible_lead, do: "Most likely responsible: #{responsible_lead}", else: ""}

      The job has been stopped. Changes remain in the job branch: deft/job-#{data.session_id}
      You can review the changes and decide how to proceed.
      """

      send_user_message(failure_message, data)
      {:next_state, {:complete, :idle}, data}
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
    # In real implementation, this would delegate to Deft.Tool
    Logger.debug("Executing tool: #{tool_call.name}")
    {:ok, "Tool result placeholder"}
  end

  defp call_llm(data) do
    # Extract parameters from data
    job_id = data.session_id
    messages = data.messages
    config = data.config
    provider_name = Map.get(config, :provider_name, "anthropic")

    # Request permission from rate limiter
    case RateLimiter.request(job_id, provider_name, messages, :foreman) do
      {:ok, _estimated_tokens} ->
        # Foreman uses empty tools list - it delegates actual work to Runners
        tools = []

        # Start streaming from the provider
        case Anthropic.stream(messages, tools, config) do
          {:ok, stream_ref} ->
            # Monitor the stream process
            monitor_ref = Process.monitor(stream_ref)
            {:ok, stream_ref, monitor_ref}

          {:error, reason} ->
            Logger.error("Foreman failed to start LLM stream: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Foreman failed to get rate limiter permission: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cancel_stream(_data) do
    # Placeholder for stream cancellation
    Logger.debug("Cancelling stream")
    :ok
  end

  defp process_provider_event(_event, data) do
    # Placeholder for processing provider events
    # In real implementation, this would accumulate text/tool calls
    data
  end

  defp done_streaming?(event) do
    # Check if this is a Done event
    match?(%Deft.Provider.Event.Done{}, event)
  end

  defp finalize_streaming(data) do
    # Finalize the current message and add to messages list
    # Placeholder implementation
    # In a full implementation, this would create a complete Message from current_message
    # and add it to data.messages, then save to session
    data = save_unsaved_messages(data)
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

  defp process_lead_message(:decision, content, metadata, data) do
    lead_id = Map.get(metadata, :lead_id)
    Logger.info("Lead #{lead_id} decision: #{content}")

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
        "Decision conflict detected for Lead #{lead_id} with Leads: #{inspect(Enum.map(conflicts, & &1.lead_id))}"
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
    Logger.info("Lead published contract")
    # Auto-promote to site log
    write_to_site_log(:contract, content, metadata, data)

    # Check for blocked Leads that can now start
    # Extract which deliverable published this contract
    lead_id = Map.get(metadata, :lead_id)
    publishing_deliverable = Map.get(metadata, :deliverable_name)

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
      "Contract from #{publishing_deliverable || lead_id} unblocked #{length(unblocked_deliverables)} deliverable(s)"
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
              "Cost ceiling reached - not starting unblocked Lead #{deliverable_name} until spending approved"
            )

            acc_data
          else
            start_lead(deliverable, acc_data)
          end
        else
          Logger.warning("Could not find deliverable #{deliverable_name} in plan")
          acc_data
        end
      end)

    updated_data
  end

  defp process_lead_message(:critical_finding, content, metadata, data) do
    Logger.info("Lead critical finding: #{content}")
    # Auto-promote to site log
    write_to_site_log(:critical_finding, content, metadata, data)
    data
  end

  defp process_lead_message(:finding, content, metadata, data) do
    Logger.debug("Lead finding: #{inspect(content)}")

    # Promote if tagged as 'shared'
    if Map.get(metadata, :shared, false) do
      Logger.info("Lead shared finding - promoting to site log")
      write_to_site_log(:research, content, metadata, data)
    end

    data
  end

  defp process_lead_message(:correction, content, metadata, data) do
    Logger.info("User correction received via Lead")
    # Auto-promote to site log
    write_to_site_log(:correction, content, metadata, data)
    data
  end

  defp process_lead_message(:status, _content, _metadata, data) do
    # Never promote status messages
    data
  end

  defp process_lead_message(:blocker, content, _metadata, data) do
    Logger.info("Lead blocker: #{content}")
    # Never promote blocker messages (coordination, not knowledge)
    data
  end

  defp process_lead_message(:artifact, content, _metadata, data) do
    Logger.info("Lead artifact: #{inspect(content)}")
    # Log artifact creation/modification
    # Don't auto-promote to site log - these are tracked via git
    data
  end

  defp process_lead_message(:contract_revision, content, metadata, data) do
    Logger.info("Lead contract revision")
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
      "Contract revision from #{publishing_deliverable || "unknown"} affects #{length(dependent_leads)} active Lead(s)"
    )

    # Send steering messages to dependent Leads
    Enum.each(dependent_leads, fn lead_id ->
      case Map.get(data.leads, lead_id) do
        nil ->
          Logger.warning("Could not find Lead #{lead_id} to re-steer")

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
            Logger.info("Sent contract revision steering to Lead #{lead_id}")
          else
            Logger.warning(
              "Lead #{lead_id} has no PID stored, cannot send steering (Lead process not yet started)"
            )
          end
      end
    end)

    data
  end

  defp process_lead_message(:plan_amendment, content, _metadata, data) do
    Logger.info("Lead plan amendment request: #{content}")
    # Lead is requesting a change to the work plan
    # Don't auto-promote - this is a coordination request
    # TODO: evaluate amendment and decide whether to approve/adjust plan
    data
  end

  defp process_lead_message(:error, content, _metadata, data) do
    Logger.error("Lead error: #{content}")
    # Log the error but don't auto-promote to site log
    # Errors are handled in Lead crash recovery, not promoted as knowledge
    data
  end

  defp process_lead_message(:complete, _content, metadata, data) do
    lead_id = Map.get(metadata, :lead_id)
    deliverable_name = Map.get(metadata, :deliverable)

    Logger.info("Lead #{lead_id} completed deliverable: #{deliverable_name}")

    # Write completion marker to site log for resume tracking
    write_to_site_log(:complete, "Deliverable #{deliverable_name} completed", metadata, data)

    # Get Lead info for worktree cleanup
    lead_info = Map.get(data.leads, lead_id)

    if is_nil(lead_info) do
      Logger.warning("Lead #{lead_id} not found in tracking map, cannot merge")
      data
    else
      handle_lead_merge(lead_id, lead_info, data)
    end
  end

  defp process_lead_message(type, content, _metadata, data) do
    Logger.debug("Lead message (#{type}): #{inspect(content)}")
    data
  end

  # Handle merging a completed Lead's branch into the job branch
  defp handle_lead_merge(lead_id, lead_info, data) do
    case GitJob.merge_lead_branch(
           lead_id: lead_id,
           job_id: data.session_id,
           working_dir: data.working_dir
         ) do
      {:ok, :merged} ->
        Logger.info("Successfully merged Lead #{lead_id} into job branch")
        handle_successful_merge(lead_id, lead_info, data)

      {:ok, :conflict, conflicted_files} ->
        handle_merge_conflict(lead_id, conflicted_files, lead_info, data)

      {:error, reason} ->
        handle_merge_error(lead_id, reason, lead_info, data)
    end
  end

  # Handle successful merge by running post-merge tests
  defp handle_successful_merge(lead_id, lead_info, data) do
    case run_post_merge_tests(data) do
      {:ok, :passed} ->
        handle_test_success(lead_id, lead_info, data)

      {:error, :test_failed, test_output} ->
        handle_test_failure(lead_id, test_output)
        data

      {:error, reason} ->
        handle_test_error(lead_id, reason)
        data
    end
  end

  # Handle successful post-merge tests
  defp handle_test_success(lead_id, lead_info, data) do
    Logger.info("Post-merge tests passed for Lead #{lead_id}")

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir)

    # Remove Lead from tracking
    leads = Map.delete(data.leads, lead_id)
    data = %{data | leads: leads}

    # Check if all Leads are done
    if all_leads_complete?(data) do
      Logger.info("All Leads complete, ready to transition to verification")
    end

    data
  end

  # Handle post-merge test failure
  defp handle_test_failure(lead_id, test_output) do
    Logger.error("Post-merge tests failed for Lead #{lead_id}. Manual intervention required.")

    send_to_self =
      {:lead_message, :critical_finding,
       "Post-merge tests failed for Lead #{lead_id}. The merge was successful but tests now fail. Manual intervention or fix-up Runner needed.\n\nTest output:\n#{String.slice(test_output, 0, 1000)}",
       %{lead_id: lead_id, test_failed: true}}

    send(self(), send_to_self)
  end

  # Handle post-merge test execution error
  defp handle_test_error(lead_id, reason) do
    Logger.error("Failed to run post-merge tests for Lead #{lead_id}: #{inspect(reason)}")

    send_to_self =
      {:lead_message, :error,
       "Failed to run post-merge tests for Lead #{lead_id}: #{inspect(reason)}",
       %{lead_id: lead_id}}

    send(self(), send_to_self)
  end

  # Handle merge conflict
  defp handle_merge_conflict(lead_id, conflicted_files, lead_info, data) do
    Logger.error("Merge conflict for Lead #{lead_id}: #{inspect(conflicted_files)}")

    send_to_self =
      {:lead_message, :critical_finding,
       "Merge conflict detected for Lead #{lead_id}: #{Enum.join(conflicted_files, ", ")}. Manual intervention required.",
       %{lead_id: lead_id, conflicted_files: conflicted_files}}

    send(self(), send_to_self)

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir)

    # Remove Lead from tracking
    leads = Map.delete(data.leads, lead_id)
    %{data | leads: leads}
  end

  # Handle merge error
  defp handle_merge_error(lead_id, reason, lead_info, data) do
    Logger.error("Failed to merge Lead #{lead_id}: #{inspect(reason)}")

    send_to_self =
      {:lead_message, :error, "Failed to merge Lead #{lead_id}: #{inspect(reason)}",
       %{lead_id: lead_id}}

    send(self(), send_to_self)

    # Clean up the Lead's worktree
    cleanup_worktree(lead_info.worktree_path, data.working_dir)

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
        Logger.debug("Wrote to site log: #{category} -> #{key}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write to site log: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp generate_site_log_key(category, metadata) do
    # Generate a human-readable key with timestamp for uniqueness
    timestamp = System.system_time(:millisecond)
    # For completion messages, use lead_id; otherwise fall back to explicit key or "entry"
    base_key = Map.get(metadata, :lead_id) || Map.get(metadata, :key, "entry")
    "#{category}-#{base_key}-#{timestamp}"
  end

  defp check_phase_transition(:complete, :executing, data) do
    # Check if all leads are complete and merged
    if all_leads_complete?(data) do
      Logger.info("All Leads complete, transitioning to verification phase")
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
    # 3. No Leads remain in the tracking map (all merged and cleaned up)
    has_plan = not is_nil(data.plan) and not is_nil(Map.get(data.plan, :deliverables))

    if has_plan do
      deliverables_count = length(Map.get(data.plan, :deliverables, []))
      started_count = MapSet.size(data.started_leads)
      remaining_leads = map_size(data.leads)

      # All deliverables started and no Leads remain
      deliverables_count > 0 and started_count == deliverables_count and remaining_leads == 0
    else
      false
    end
  end

  defp generate_message_id do
    "msg_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
  end

  # Runs post-merge tests on the job branch using the configured test command.
  # This catches semantic conflicts that may not show up as merge conflicts.
  defp run_post_merge_tests(data) do
    # Get test command from config (defaults to "mix test")
    test_command = Map.get(data.config, :job_test_command, "mix test")

    GitJob.run_post_merge_tests(
      job_id: data.session_id,
      test_command: test_command,
      working_dir: data.working_dir
    )
  end

  # Cleans up a Lead's worktree when the Lead crashes.
  # Uses `git worktree remove --force` to handle cases where index.lock exists.
  defp cleanup_worktree(worktree_path, working_dir) do
    # Change to working directory to ensure git command operates in correct repo
    File.cd!(working_dir, fn ->
      # Use --force to remove worktree even if index.lock exists
      {output, exit_code} = Git.cmd(["worktree", "remove", "--force", worktree_path])

      case exit_code do
        0 ->
          Logger.info("Successfully removed worktree: #{worktree_path}")
          :ok

        _ ->
          Logger.error("Failed to remove worktree #{worktree_path}: #{output}")
          {:error, output}
      end
    end)
  end

  # Cleans up all remaining Lead worktrees on job completion, failure, or abort.
  # Iterates through all Leads tracked in data.leads and removes their worktrees.
  defp cleanup_all_lead_worktrees(data) do
    if map_size(data.leads) == 0 do
      Logger.debug("No Lead worktrees to clean up")
    else
      Logger.info("Cleaning up #{map_size(data.leads)} Lead worktree(s)")

      Enum.each(data.leads, fn {lead_id, lead_info} ->
        worktree_path = lead_info.worktree_path
        Logger.info("Cleaning up worktree for Lead #{lead_id}: #{worktree_path}")
        cleanup_worktree(worktree_path, data.working_dir)
      end)

      Logger.info("All Lead worktrees cleaned up")
    end

    :ok
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
        Logger.info("Archived job files for job #{job_id} with status: #{status}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write status file for job #{job_id}: #{inspect(reason)}")
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
    provider_name = Map.get(data.config, :provider, "anthropic")
    # Default model for resolving provider
    model_name = Map.get(data.config, :lead_model, "claude-sonnet-4")

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

  # Determine the next phase after completing current agent loop
  # Returns {next_state, updated_data}
  defp determine_next_phase(:planning, data) do
    # After planning completes, transition to researching
    {{:researching, :idle}, data}
  end

  defp determine_next_phase(:decomposing, data) do
    # After decomposition completes, extract plan and wait for approval
    # The plan should be in the last assistant message
    plan = extract_plan_from_messages(data.messages)

    if plan do
      # Write plan to site log
      write_plan_to_site_log(plan, data)

      # Check if auto-approve is enabled
      auto_approve = Map.get(data.config, :auto_approve_all, false)

      if auto_approve do
        Logger.info("Auto-approving plan (--auto-approve-all enabled)")
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
      Logger.warning("Failed to extract plan from decomposition response")
      {{:decomposing, :idle}, data}
    end
  end

  defp determine_next_phase(job_phase, data) do
    # For other phases, stay in idle within the same phase
    {{job_phase, :idle}, data}
  end

  # Build decomposition prompt with research findings
  defp build_decomposition_prompt(data) do
    # Format research findings
    findings_text =
      if Enum.empty?(data.research_findings) do
        "No research findings available."
      else
        data.research_findings
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {finding, idx} ->
          "## Research Finding #{idx}\n\n#{inspect(finding)}"
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

  # Extract plan from the last assistant message
  # Returns a map with deliverables, dag, contracts, and estimates
  # Returns nil if no valid plan found
  defp extract_plan_from_messages(messages) do
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
                Logger.warning("Failed to parse plan from response")
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
        Logger.info("Wrote plan to #{plan_path}")

        # Also write to site log
        write_to_site_log(:plan, Jason.encode!(plan), %{key: "work-plan"}, data)

      {:error, reason} ->
        Logger.error("Failed to encode plan as JSON: #{inspect(reason)}")
    end
  end

  # Present plan to user for approval
  defp present_plan_for_approval(plan, _data) do
    # In a real implementation, this would send the plan to the TUI for display
    # For now, just log it
    Logger.info("Plan ready for approval:\n#{plan.raw_plan}")
    Logger.info("Waiting for user approval (send {:approve_plan} or {:reject_plan} message)")
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
            Logger.warning("Failed to parse contract spec: #{contract_spec}")
            acc
        end
      end)

    Logger.info("Built dependency tracking: #{inspect(blocked_leads)}")

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

    Logger.info("Starting Lead for deliverable: #{deliverable.name} (#{lead_id})")

    # Create worktree for this Lead
    case GitJob.create_lead_worktree(
           lead_id: lead_id,
           job_id: data.session_id,
           working_dir: data.working_dir
         ) do
      {:ok, worktree_path} ->
        # Start RunnerSupervisor (Task.Supervisor) for this Lead
        runner_supervisor_name =
          {:via, Registry, {Deft.ProcessRegistry, {:runner_supervisor, lead_id}}}

        {:ok, _runner_supervisor_pid} = Task.Supervisor.start_link(name: runner_supervisor_name)

        # Get site log name
        site_log_name = {:sitelog, data.session_id}

        # Start Lead gen_statem process
        lead_opts = [
          lead_id: lead_id,
          session_id: data.session_id,
          config: data.config,
          deliverable: deliverable.description,
          foreman_pid: self(),
          site_log_name: site_log_name,
          rate_limiter_pid: data.rate_limiter_pid,
          worktree_path: worktree_path,
          working_dir: data.working_dir,
          runner_supervisor: runner_supervisor_name
        ]

        case Lead.start_link(lead_opts) do
          {:ok, lead_pid} ->
            # Monitor the Lead process
            monitor_ref = Process.monitor(lead_pid)

            lead_info = %{
              deliverable: deliverable,
              worktree_path: worktree_path,
              status: :running,
              pid: lead_pid,
              monitor_ref: monitor_ref,
              runner_supervisor: runner_supervisor_name
            }

            leads = Map.put(data.leads, lead_id, lead_info)
            started_leads = MapSet.put(data.started_leads, deliverable.name)

            Logger.info(
              "Lead #{lead_id} started with PID #{inspect(lead_pid)} and worktree at #{worktree_path}"
            )

            %{data | leads: leads, started_leads: started_leads}

          {:error, reason} ->
            Logger.error("Failed to start Lead #{lead_id}: #{inspect(reason)}")
            data
        end

      {:error, reason} ->
        Logger.error("Failed to create worktree for Lead #{lead_id}: #{inspect(reason)}")
        data
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
          Logger.warning("Cannot pause Lead #{lead_id} - not found")
          acc_data

        lead_info ->
          # Update Lead status to paused
          updated_lead_info = %{lead_info | status: :paused}
          updated_leads = Map.put(acc_data.leads, lead_id, updated_lead_info)

          # Send steering message to pause the Lead
          send(lead_info.pid, {:foreman_steering, build_pause_message()})

          Logger.info("Paused Lead #{lead_id} due to decision conflict")

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

    Logger.warning("Decision conflict requiring resolution:\n#{conflict_summary}")

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

  defp analyze_verification_results(results) do
    # Results from the verification Runner - check for test failures or quality issues
    # The Runner returns a map with findings
    case results do
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
        Logger.warning("Unexpected verification result format: #{inspect(results)}")
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

  defp send_user_message(message, _data) do
    # Log the message - in a real implementation this would send to the TUI
    Logger.info("Message to user:\n#{message}")
    # TODO: Send to TUI/user interface
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
    site_log_keys = Store.keys(Store.tid(data.site_log_pid))

    # Look for "complete-lead-*" entries
    completed_lead_ids =
      site_log_keys
      |> Enum.filter(&String.starts_with?(&1, "complete-"))
      |> Enum.map(fn key ->
        # Extract lead_id from the key
        case String.split(key, "-", parts: 3) do
          ["complete", lead_id | _] -> lead_id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Map lead_ids back to deliverable names
    # Lead IDs are formatted as "<job_id>-<deliverable_name>"
    completed_deliverables =
      completed_lead_ids
      |> Enum.map(fn lead_id ->
        # Extract deliverable name from lead_id
        # Lead ID format: "#{session_id}-#{deliverable.name}"
        case String.split(lead_id, "-", parts: 2) do
          [_session_id, deliverable_name] -> deliverable_name
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    completed_deliverables
  end
end
