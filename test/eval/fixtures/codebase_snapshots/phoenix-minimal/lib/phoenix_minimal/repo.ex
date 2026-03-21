defmodule PhoenixMinimal.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_minimal,
    adapter: Ecto.Adapters.Postgres
end
