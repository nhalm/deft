defmodule Deft.Application do
  @moduledoc """
  OTP Application for Deft.

  The application supervisor starts the core services required for Deft to operate.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Additional children will be added as specs are implemented
    ]

    opts = [strategy: :one_for_one, name: Deft.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
