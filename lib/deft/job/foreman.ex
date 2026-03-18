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
  alias Deft.Agent.ToolRunner
  alias Deft.Store
  alias Deft.Project
  alias Deft.Git
  alias Deft.Job.Runner

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
      site_log_pid: nil
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

    # Start in planning phase, idle agent state
    initial_state = {:planning, :idle}
    data = %{initial_data | site_log_pid: site_log_pid}
    {:ok, initial_state, data}
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
          Task.Supervisor.async_nolink(ToolRunner, fn ->
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
              data.rate_limiter_pid,
              runner_config,
              data.working_dir
            )
          end)

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
  def handle_event(:cast, {:prompt, text}, {job_phase, :idle}, data) do
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

    # Transition to complete phase
    {:next_state, {:complete, :idle},
     %{data | stream_ref: nil, stream_monitor_ref: nil, tool_tasks: []}}
  end

  # Plan approval handling
  def handle_event(:cast, :approve_plan, {:decomposing, :idle}, data) do
    Logger.info("Plan approved by user, transitioning to execution phase")
    {:next_state, {:executing, :idle}, data}
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
    new_cost = data.session_cost + amount
    {:keep_state, %{data | session_cost: new_cost}}
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
        next_state = determine_next_phase(job_phase, data)
        {:next_state, next_state, data}
      end
    else
      {:keep_state, data}
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

  defp call_llm(_data) do
    # Placeholder for LLM call
    # In real implementation, this would use the rate limiter and provider
    Logger.debug("Calling LLM")
    {:ok, make_ref(), make_ref()}
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
    Logger.info("Lead decision: #{content}")
    # Auto-promote to site log
    write_to_site_log(:decision, content, metadata, data)
    data
  end

  defp process_lead_message(:contract, content, metadata, data) do
    Logger.info("Lead published contract")
    # Auto-promote to site log and trigger partial unblocking
    write_to_site_log(:contract, content, metadata, data)
    # TODO: check for blocked leads that can now start
    data
  end

  defp process_lead_message(:complete, _content, _metadata, data) do
    Logger.info("Lead completed deliverable")
    # TODO: merge lead branch, check if all leads done
    data
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

  defp process_lead_message(type, content, _metadata, data) do
    Logger.debug("Lead message (#{type}): #{inspect(content)}")
    data
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
    base_key = Map.get(metadata, :key, "entry")
    "#{category}-#{base_key}-#{timestamp}"
  end

  defp check_phase_transition(:complete, :executing, _data) do
    # Check if all leads are complete
    # If so, transition to verifying
    # This is a placeholder - real implementation would check lead status
    {:transition, :verifying}
  end

  defp check_phase_transition(_type, _phase, _data) do
    :no_transition
  end

  defp generate_message_id do
    "msg_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
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
  defp determine_next_phase(:planning, _data) do
    # After planning completes, transition to researching
    {:researching, :idle}
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
        # Transition directly to executing
        {:executing, :idle}
      else
        # Present plan to user and stay in decomposing until approved
        present_plan_for_approval(plan, data)
        # Stay in decomposing:idle waiting for user approval
        {:decomposing, :idle}
      end
    else
      # No valid plan extracted, stay in decomposing
      Logger.warning("Failed to extract plan from decomposition response")
      {:decomposing, :idle}
    end
  end

  defp determine_next_phase(job_phase, _data) do
    # For other phases, stay in idle within the same phase
    {job_phase, :idle}
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

        # For now, return the raw text as the plan
        # In a real implementation, this would parse structured JSON or markdown
        %{
          raw_plan: text_content,
          deliverables: [],
          dependencies: [],
          contracts: [],
          estimates: %{duration: "unknown", cost: "unknown"}
        }
    end
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
end
