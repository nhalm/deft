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
end
