defmodule Deft.Session.Supervisor do
  @moduledoc """
  Dynamic supervisor for Deft sessions.

  Manages per-session process subtrees. Each session is started on demand
  and runs as an isolated process group. A crash in one session does not
  affect other sessions.
  """

  use DynamicSupervisor

  @doc """
  Starts the Session Supervisor.
  """
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new session.

  Returns `{:ok, pid}` where pid is the session worker supervisor.

  ## Options

  - `:session_id` — Required. Unique identifier for the session.
  - `:config` — Required. Configuration map for the agent.
  - `:messages` — Optional. Initial conversation messages (default: []).
  - `:om_snapshot` — Optional. OM snapshot to restore from (for session resume).
  """
  def start_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    messages = Keyword.get(opts, :messages, [])
    om_snapshot = Keyword.get(opts, :om_snapshot)

    worker_opts = [
      session_id: session_id,
      config: config,
      messages: messages,
      om_snapshot: om_snapshot
    ]

    child_spec = %{
      id: {:session, session_id},
      start: {Deft.Session.Worker, :start_link, [worker_opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
