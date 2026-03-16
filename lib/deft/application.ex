defmodule Deft.Application do
  @moduledoc """
  OTP Application for Deft.

  The application supervisor starts the core services required for Deft to operate.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Deft.Provider.Registry,
      Deft.Session.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Deft.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
