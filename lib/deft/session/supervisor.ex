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
  - `:project_dir` — Optional. Project directory to scan for skills/commands (default: `File.cwd!/0`).
  """
  def start_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    messages = Keyword.get(opts, :messages, [])
    session_cost = Keyword.get(opts, :session_cost, 0.0)
    om_snapshot = Keyword.get(opts, :om_snapshot)
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    # Re-scan project-level skills and commands
    # Built-in and global skills persist; project skills are refreshed each session
    Deft.Skills.Registry.rescan_project(project_dir)

    worker_opts = [
      session_id: session_id,
      config: config,
      messages: messages,
      session_cost: session_cost,
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
