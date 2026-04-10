defmodule Deft.Session.Worker do
  @moduledoc """
  Per-session worker supervisor.

  Every session starts a Foreman along with all orchestration infrastructure.
  The Foreman handles simple tasks directly (solo mode) and orchestrates
  complex tasks by spawning Leads.

  Supervision tree (rest_for_one strategy):
  - Deft.Store (site log)
  - Deft.RateLimiter
  - Deft.Agent.ToolRunner (Foreman's tool execution)
  - Deft.Foreman (LLM loop, OM, session)
  - Task.Supervisor (research/verification Runners)
  - Deft.OM.Supervisor
  - Deft.Foreman.Coordinator (orchestration gen_statem)
  - Deft.LeadSupervisor (dynamic supervisor for Leads)
  """

  use Supervisor

  alias Deft.Project

  @doc """
  Starts the session worker supervisor.

  ## Options

  - `:session_id` — Required. Unique identifier for the session.
  - `:config` — Required. Configuration map for the agent.
  - `:messages` — Optional. Initial conversation messages (default: []).
  - `:om_snapshot` — Optional. OM snapshot to restore from (for session resume).
  - `:prompt` — Optional. Initial user prompt (for deft work).
  - `:working_dir` — Required. Working directory.
  - `:resumed_plan` — Optional. Plan to resume from.
  - `:cli_pid` — Optional. CLI process PID for plan approval messages.
  - `:session_cost` — Optional. Initial session cost (default: 0.0).
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    messages = Keyword.get(opts, :messages, [])
    prompt = Keyword.get(opts, :prompt)
    working_dir = Keyword.fetch!(opts, :working_dir)
    resumed_plan = Keyword.get(opts, :resumed_plan)
    cli_pid = Keyword.get(opts, :cli_pid)
    om_snapshot = Keyword.get(opts, :om_snapshot)

    # Build paths for Stores
    jobs_dir = Project.jobs_dir(working_dir)
    sitelog_path = Path.join([jobs_dir, session_id, "sitelog.dets"])
    cache_dir = Project.cache_dir(working_dir)
    # Default lead_id for Foreman's cache
    lead_id = "main"
    cache_dets_path = Path.join([cache_dir, session_id, "lead-#{lead_id}.dets"])

    # Build via_tuples for process registration
    rate_limiter_name = {:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, session_id}}}
    foreman_name = {:via, Registry, {Deft.ProcessRegistry, {:foreman, session_id}}}

    foreman_coordinator_name =
      {:via, Registry, {Deft.ProcessRegistry, {:foreman_coordinator, session_id}}}

    foreman_tool_runner_name =
      {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}

    runner_supervisor_name =
      {:via, Registry, {Deft.ProcessRegistry, {:foreman_runner_supervisor, session_id}}}

    # Store session-level data for cleanup
    Process.put(:session_cleanup_data, %{
      session_id: session_id,
      jobs_dir: jobs_dir,
      cache_dir: cache_dir
    })

    children = [
      # 1. Cache Store — tool result spilling for Foreman (must start before Foreman agent)
      {Deft.Store,
       [
         name: {:cache, session_id, lead_id},
         type: :cache,
         dets_path: cache_dets_path
       ]},

      # 2. Store (site log instance)
      %{
        id: :sitelog,
        start:
          {Deft.Store, :start_link,
           [
             [
               name: {:sitelog, session_id},
               type: :sitelog,
               dets_path: sitelog_path,
               owner_name: {:foreman, session_id}
             ]
           ]},
        restart: :temporary
      },

      # 3. RateLimiter
      %{
        id: Deft.RateLimiter,
        start:
          {Deft.RateLimiter, :start_link,
           [
             [
               job_id: session_id,
               foreman_pid: foreman_coordinator_name,
               cost_ceiling: config.work_cost_ceiling,
               initial_concurrency: config.job_initial_concurrency,
               max_concurrency: config.job_max_leads
             ]
           ]},
        restart: :temporary
      },

      # 4. ToolRunner for Foreman's tool execution
      %{
        id: :foreman_tool_runner,
        start: {Deft.Agent.ToolRunner, :start_link, [[name: foreman_tool_runner_name]]},
        type: :supervisor
      },

      # 5. Foreman (standard Deft.Agent with Foreman configuration)
      %{
        id: Deft.Foreman,
        start:
          {Deft.Foreman, :start_link,
           [
             [
               session_id: session_id,
               config: config,
               parent_pid: foreman_coordinator_name,
               rate_limiter: rate_limiter_name,
               working_dir: working_dir,
               messages: messages,
               name: foreman_name
             ]
           ]},
        restart: :temporary
      },

      # 6. RunnerSupervisor for Foreman's Runners (research, verification, merge-resolution)
      %{
        id: :foreman_runner_supervisor,
        start: {Task.Supervisor, :start_link, [[name: runner_supervisor_name]]},
        type: :supervisor
      },

      # 7. OM.Supervisor — Observational memory processes
      {Deft.OM.Supervisor,
       [session_id: session_id, config: config, messages: messages, snapshot: om_snapshot]},

      # 8. Foreman.Coordinator (orchestration gen_statem)
      %{
        id: Deft.Foreman.Coordinator,
        start:
          {Deft.Foreman.Coordinator, :start_link,
           [
             [
               session_id: session_id,
               config: config,
               prompt: prompt,
               rate_limiter_pid: rate_limiter_name,
               foreman_agent_pid: foreman_name,
               runner_supervisor: runner_supervisor_name,
               working_dir: working_dir,
               resumed_plan: resumed_plan,
               cli_pid: cli_pid,
               name: foreman_coordinator_name
             ]
           ]},
        restart: :temporary
      },

      # 9. LeadSupervisor (dynamic supervisor for Leads)
      %{
        id: Deft.LeadSupervisor,
        start: {Deft.LeadSupervisor, :start_link, [[job_id: session_id]]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def terminate(_reason, _state) do
    # Clean up session directories on termination
    _ =
      case Process.get(:session_cleanup_data) do
        %{session_id: session_id, jobs_dir: jobs_dir, cache_dir: cache_dir} ->
          session_job_dir = Path.join(jobs_dir, session_id)
          session_cache_dir = Path.join(cache_dir, session_id)

          _ =
            if File.exists?(session_job_dir) do
              File.rm_rf(session_job_dir)
            end

          _ =
            if File.exists?(session_cache_dir) do
              File.rm_rf(session_cache_dir)
            end

          :ok

        _ ->
          :ok
      end

    :ok
  end

  @doc """
  Returns the Registry via tuple for the session worker.
  """
  def via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:session_worker, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the Foreman.Coordinator process.
  """
  def foreman_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:foreman, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the Foreman agent process.
  """
  def foreman_agent_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:foreman, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the RateLimiter.
  """
  def rate_limiter_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the ToolRunner supervisor.
  """
  def tool_runner_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the site log store.
  """
  def sitelog_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:sitelog, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the Runner supervisor.
  """
  def runner_supervisor_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:foreman_runner_supervisor, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the cache store.
  """
  def cache_via_tuple(session_id, lead_id \\ "main") do
    {:via, Registry, {Deft.ProcessRegistry, {:cache, session_id, lead_id}}}
  end

  @doc """
  Returns the Registry via tuple for the agent process.

  NOTE: This is a compatibility alias for foreman_agent_via_tuple/1.
  In the unified architecture, every session starts a Foreman.
  This function exists to support code that hasn't been migrated yet.
  """
  def agent_via_tuple(session_id) do
    foreman_agent_via_tuple(session_id)
  end
end
