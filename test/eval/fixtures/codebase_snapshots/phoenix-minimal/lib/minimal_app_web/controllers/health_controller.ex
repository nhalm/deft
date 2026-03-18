defmodule MinimalAppWeb.HealthController do
  use MinimalAppWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
