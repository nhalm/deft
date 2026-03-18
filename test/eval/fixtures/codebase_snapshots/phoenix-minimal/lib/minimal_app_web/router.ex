defmodule MinimalAppWeb.Router do
  use MinimalAppWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", MinimalAppWeb do
    pipe_through(:api)

    get("/health", HealthController, :show)
  end
end
