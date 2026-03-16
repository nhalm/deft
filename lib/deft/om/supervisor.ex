defmodule Deft.OM.Supervisor do
  @moduledoc """
  Supervisor for Observational Memory processes.

  This is a stub implementation. Full OM functionality will be implemented
  in future work items.
  """

  use Supervisor

  @doc """
  Starts the OM supervisor.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: name_for_session(opts))
  end

  @impl true
  def init(_opts) do
    # No children yet - full OM implementation comes later
    children = []

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp name_for_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    {:via, Registry, {Deft.Registry, {:om_supervisor, session_id}}}
  end
end
