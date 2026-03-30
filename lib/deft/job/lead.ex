defmodule Deft.Job.Lead do
  @moduledoc """
  Lead orchestrator — manages a single deliverable using a gen_statem with 4 pure orchestration states.

  The v0.7 redesign splits the Lead into two processes:
  - Lead (this module): Pure orchestration gen_statem managing deliverable lifecycle
  - LeadAgent: Standard Deft.Agent that does LLM reasoning

  ## Lead Phase States

  - `:planning` — Sends deliverable assignment to LeadAgent, which decomposes into tasks
  - `:executing` — Spawns Runners on request, collects results, sends to LeadAgent
  - `:verifying` — Spawns testing Runner
  - `:complete` — Sends `:complete` to Foreman

  ## Communication

  **Lead → LeadAgent:** Via `Deft.Agent.prompt/2`
  **LeadAgent → Lead:** Via orchestration tools that send `{:agent_action, action, payload}` messages
  **Foreman → Lead:** Via `{:foreman_steering, content}` messages
  **Lead → Foreman:** Via `{:lead_message, type, content, metadata}` messages

  ## Runner Management

  Runners are spawned via `Task.Supervisor.async_nolink`. The Lead monitors each Runner
  task via Task refs for completion.
  """

  @behaviour :gen_statem

  alias Deft.Job.Runner

  require Logger

  # Client API

  @doc """
  Starts the Lead gen_statem.

  ## Options

  - `:lead_id` — Required. Unique identifier for this Lead.
  - `:session_id` — Required. Job session identifier.
  - `:config` — Required. Configuration map.
  - `:deliverable` — Required. Deliverable assignment (map with name, description, etc.).
  - `:foreman_pid` — Required. PID of the Foreman for messaging.
  - `:site_log_name` — Required. Registered name of Deft.Store site log instance.
  - `:rate_limiter_pid` — Required. PID of Deft.Job.RateLimiter.
  - `:worktree_path` — Required. Path to Lead's git worktree.
  - `:working_dir` — Required. Project working directory for cache path resolution.
  - `:runner_supervisor` — Required. Name/PID of the Lead's Task.Supervisor for Runners.
  - `:lead_agent_pid` — Optional. PID of the LeadAgent (will be set by supervisor).
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
      lead_start_time: System.monotonic_time(:millisecond)
    }

    gen_statem_opts = if name, do: [name: name], else: []
    :gen_statem.start_link(__MODULE__, initial_data, gen_statem_opts)
  end

  @doc """
  Sets the LeadAgent PID after the agent is started by the supervisor.
  """
  def set_lead_agent(lead, agent_pid) do
    :gen_statem.cast(lead, {:set_lead_agent, agent_pid})
  end

  @doc """
  Sends Foreman steering to the Lead.
  """
  def steer(lead, content) do
    send(lead, {:foreman_steering, content})
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(data) do
    Logger.info(
      "Lead #{data.lead_id} started for deliverable: #{inspect(data.deliverable[:name])}"
    )

    {:ok, :planning, data}
  end

  # State enter callbacks

  @impl :gen_statem
  def handle_event(:enter, _old_state, :planning, data) do
    Logger.info("Lead #{data.lead_id} entering :planning phase")

    # Send deliverable assignment to LeadAgent
    if data.lead_agent_pid do
      context = build_planning_context(data)
      Deft.Agent.prompt(data.lead_agent_pid, context)
    end

    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :executing, _data) do
    Logger.info("Lead entering :executing phase")
    # Runners will be spawned based on LeadAgent requests
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :verifying, data) do
    Logger.info("Lead #{data.lead_id} entering :verifying phase")
    # Spawn testing Runner
    data = spawn_testing_runner(data)
    {:keep_state, data}
  end

  def handle_event(:enter, _old_state, :complete, data) do
    Logger.info("Lead #{data.lead_id} entering :complete phase")
    # Send completion to Foreman
    send_to_foreman(data, :complete, "Deliverable completed", %{
      lead_id: data.lead_id,
      deliverable: data.deliverable
    })

    :keep_state_and_data
  end

  # Set LeadAgent PID
  def handle_event(:cast, {:set_lead_agent, agent_pid}, _state, data) do
    Logger.debug("Lead #{data.lead_id} - LeadAgent PID set: #{inspect(agent_pid)}")
    data = Map.put(data, :lead_agent_pid, agent_pid)
    {:keep_state, data}
  end

  # Handle agent actions from LeadAgent orchestration tools

  def handle_event(:info, {:agent_action, :spawn_runner, type, instructions}, state, data)
      when state in [:planning, :executing] do
    Logger.info("Lead #{data.lead_id} - LeadAgent requested spawning #{type} Runner")

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

    # Track the task
    runner_tasks = Map.put(data.runner_tasks, task.ref, %{type: type, task: task})
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
    Logger.info("Lead #{data.lead_id} - LeadAgent publishing contract")

    send_to_foreman(data, :contract, content, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :report, report_type, content}, state, data)
      when state in [:planning, :executing] do
    Logger.info("Lead #{data.lead_id} - LeadAgent reporting: #{report_type}")

    send_to_foreman(data, report_type, content, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  def handle_event(:info, {:agent_action, :blocker, description}, state, data)
      when state in [:planning, :executing] do
    Logger.warning("Lead #{data.lead_id} - LeadAgent blocked: #{description}")

    send_to_foreman(data, :blocker, description, %{
      lead_id: data.lead_id,
      deliverable: data.deliverable[:name]
    })

    :keep_state_and_data
  end

  # Handle Runner task completion
  def handle_event(:info, {ref, result}, state, data) when is_reference(ref) do
    case Map.pop(data.runner_tasks, ref) do
      {nil, _tasks} ->
        # Not our task
        :keep_state_and_data

      {runner_info, remaining_tasks} ->
        Logger.info("Lead #{data.lead_id} - Runner #{runner_info.type} completed")

        # Store result
        runner_results = [
          %{type: runner_info.type, result: result} | data.runner_results
        ]

        data =
          data
          |> Map.put(:runner_tasks, remaining_tasks)
          |> Map.put(:runner_results, runner_results)

        # Send results to LeadAgent
        if data.lead_agent_pid do
          context = build_runner_result_context(runner_info.type, result)
          Deft.Agent.prompt(data.lead_agent_pid, context)
        end

        # If in verifying and no more tasks, transition to complete
        if state == :verifying and map_size(remaining_tasks) == 0 do
          {:next_state, :complete, data}
        else
          {:keep_state, data}
        end
    end
  end

  # Handle Runner task DOWN (process exit)
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    case Map.pop(data.runner_tasks, ref) do
      {nil, _tasks} ->
        :keep_state_and_data

      {runner_info, remaining_tasks} ->
        Logger.error(
          "Lead #{data.lead_id} - Runner #{runner_info.type} failed: #{inspect(reason)}"
        )

        data = Map.put(data, :runner_tasks, remaining_tasks)

        # Report error to Foreman
        send_to_foreman(data, :error, "Runner #{runner_info.type} failed: #{inspect(reason)}", %{
          lead_id: data.lead_id,
          runner_type: runner_info.type
        })

        # Send failure to LeadAgent for recovery
        if data.lead_agent_pid do
          context =
            "Runner #{runner_info.type} failed: #{inspect(reason)}. Please adjust approach."

          Deft.Agent.prompt(data.lead_agent_pid, context)
        end

        {:keep_state, data}
    end
  end

  # Handle Foreman steering
  def handle_event(:info, {:foreman_steering, content}, state, data)
      when state in [:planning, :executing] do
    Logger.info("Lead #{data.lead_id} - Received steering from Foreman")

    # Inject steering into LeadAgent as a prompt
    if data.lead_agent_pid do
      steering_prompt = """
      FOREMAN STEERING:
      #{content}

      Please adjust your approach accordingly.
      """

      Deft.Agent.prompt(data.lead_agent_pid, steering_prompt)
    end

    :keep_state_and_data
  end

  # Fallback for unexpected events
  def handle_event(event_type, event_content, state, data) do
    Logger.warning(
      "Lead #{data.lead_id} - Unhandled event in state #{state}: #{event_type} #{inspect(event_content)}"
    )

    :keep_state_and_data
  end

  # Private helpers

  defp build_planning_context(data) do
    """
    You are the LeadAgent managing the following deliverable:

    **Deliverable:** #{data.deliverable[:name]}
    **Description:** #{data.deliverable[:description] || "No description provided"}

    **Your responsibilities:**
    1. Read the deliverable assignment and research findings from the site log
    2. Decompose the deliverable into concrete implementation tasks
    3. Use your available tools to spawn Runners, publish contracts, and report progress
    4. Evaluate Runner output and request corrective Runners if needed
    5. Request testing Runners to verify compile checks and tests

    **Available tools:**
    - `spawn_runner` — Start a Runner to execute a task
    - `publish_contract` — Publish an interface contract for dependent Leads
    - `report_status` — Send progress updates to the Foreman
    - `request_help` — Escalate blockers to the Foreman

    **Worktree path:** #{data.worktree_path}

    Begin by analyzing the deliverable and planning your approach. When ready, spawn your first Runner.
    """
  end

  defp build_runner_result_context(runner_type, result) do
    """
    Runner #{runner_type} completed with the following result:

    #{inspect(result, pretty: true)}

    Please evaluate this output and decide on the next step:
    - If successful, proceed to the next task or verify the deliverable
    - If there are issues, spawn a corrective Runner
    - If the deliverable is complete, transition to verification
    """
  end

  defp spawn_testing_runner(data) do
    Logger.info("Lead #{data.lead_id} - Spawning testing Runner")

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

    runner_tasks = Map.put(data.runner_tasks, task.ref, %{type: :testing, task: task})
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
    send(data.foreman_pid, {:lead_message, type, content, metadata})
  end
end
