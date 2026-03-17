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
    om_snapshot = Keyword.get(opts, :om_snapshot)

    children = [
      # 1. Agent — the core agent loop
      {Deft.Agent,
       [
         session_id: session_id,
         config: config,
         messages: messages,
         name: agent_via_tuple(session_id)
       ]},

      # 2. ToolRunner — Task.Supervisor for tool execution
      {Deft.Agent.ToolRunner, [name: tool_runner_via_tuple(session_id)]},

      # 3. OM.Supervisor — Observational memory processes
      {Deft.OM.Supervisor,
       [session_id: session_id, config: config, messages: messages, snapshot: om_snapshot]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Returns the Registry via tuple for the session worker.
  """
  def via_tuple(session_id) do
    {:via, Registry, {Deft.Registry, {:session_worker, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the agent process.
  """
  def agent_via_tuple(session_id) do
    {:via, Registry, {Deft.Registry, {:agent, session_id}}}
  end

  @doc """
  Returns the Registry via tuple for the ToolRunner supervisor.
  """
  def tool_runner_via_tuple(session_id) do
    {:via, Registry, {Deft.Registry, {:tool_runner, session_id}}}
  end
end
