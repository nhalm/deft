defmodule Deft.Session.Worker do
  @moduledoc """
  Per-session worker supervisor.

  Supervises the agent loop, tool runner, and observational memory processes
  for a single session. Uses `rest_for_one` strategy so that:
  - If Agent crashes, ToolRunner and OM restart
  - If ToolRunner crashes, only OM restarts
  - If OM crashes, only OM restarts

  Each session runs as an isolated process subtree.
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
    session_cost = Keyword.get(opts, :session_cost, 0.0)
    om_snapshot = Keyword.get(opts, :om_snapshot)

    # Build cache DETS path
    working_dir = Map.get(config, :working_dir, File.cwd!())
    cache_dir = Project.cache_dir(working_dir)
    # Default lead_id for single-agent sessions
    lead_id = "main"
    cache_dets_path = Path.join([cache_dir, session_id, "lead-#{lead_id}.dets"])

    # Store session-level data for cleanup
    # Store session_id and cache_dir in supervisor state for terminate/2
    Process.put(:session_cleanup_data, %{
      session_id: session_id,
      cache_dir: cache_dir
    })

    children = [
      # 1. Cache Store — tool result spilling (must start before Agent)
      {Deft.Store,
       [
         name: {:cache, session_id, lead_id},
         type: :cache,
         dets_path: cache_dets_path
       ]},

      # 2. Agent — the core agent loop
      {Deft.Agent,
       [
         session_id: session_id,
         config: config,
         messages: messages,
         session_cost: session_cost,
         name: agent_via_tuple(session_id)
       ]},

      # 3. ToolRunner — Task.Supervisor for tool execution
      {Deft.Agent.ToolRunner, [name: tool_runner_via_tuple(session_id)]},

      # 4. OM.Supervisor — Observational memory processes
      {Deft.OM.Supervisor,
       [session_id: session_id, config: config, messages: messages, snapshot: om_snapshot]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def terminate(_reason, _state) do
    # Clean up session cache directory on termination
    case Process.get(:session_cleanup_data) do
      %{session_id: session_id, cache_dir: cache_dir} ->
        session_cache_dir = Path.join(cache_dir, session_id)

        if File.exists?(session_cache_dir) do
          File.rm_rf(session_cache_dir)
        end

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
  Returns the Registry via tuple for the agent process.
  """
  def agent_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:agent, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the ToolRunner supervisor.
  """
  def tool_runner_via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the cache store.
  """
  def cache_via_tuple(session_id, lead_id \\ "main") do
    {:via, Registry, {Deft.ProcessRegistry, {:cache, session_id, lead_id}}}
  end
end
