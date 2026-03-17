defmodule Deft.Application do
  @moduledoc """
  OTP Application for Deft.

  The application supervisor starts the core services required for Deft to operate.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Event broadcasting registry (duplicate keys for pub/sub)
      {Registry, keys: :duplicate, name: Deft.Registry},
      # Process naming registry (unique keys for :via tuples)
      {Registry, keys: :unique, name: Deft.ProcessRegistry},
      Deft.Provider.Registry,
      Deft.Skills.Registry,
      Deft.Session.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Deft.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
