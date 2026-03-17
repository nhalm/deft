defmodule Deft.OM.Supervisor do
  @moduledoc """
  Supervisor for Observational Memory processes.

  Supervision tree (rest_for_one strategy):
  - Task.Supervisor (for Observer/Reflector LLM calls)
  - Deft.OM.State (GenServer holding observation state)

  With rest_for_one:
  - If TaskSupervisor crashes, State also restarts (clean flags)
  - If State crashes, TaskSupervisor is unaffected
  """

  use Supervisor

  @doc """
  Starts the OM supervisor.

  ## Options

  - `:session_id` — Required. Session identifier.
  - `:config` — Required. Configuration struct.
  - `:messages` — Optional. Messages for computing pending tokens on resume.
  - `:snapshot` — Optional. Observation entry to restore from.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: name_for_session(opts))
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    messages = Keyword.get(opts, :messages, [])
    snapshot = Keyword.get(opts, :snapshot)

    children = [
      # TaskSupervisor starts FIRST (with rest_for_one, if this crashes, State also restarts)
      {Task.Supervisor, name: task_supervisor_name(session_id)},
      # State starts SECOND (if this crashes, TaskSupervisor is unaffected)
      {Deft.OM.State,
       session_id: session_id, config: config, messages: messages, snapshot: snapshot}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Returns the name for the TaskSupervisor for the given session.
  """
  def task_supervisor_name(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:om_task_supervisor, session_id}}}
  end

  defp name_for_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    {:via, Registry, {Deft.ProcessRegistry, {:om_supervisor, session_id}}}
  end
end
