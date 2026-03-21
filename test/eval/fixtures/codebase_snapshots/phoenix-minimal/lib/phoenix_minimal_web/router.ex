defmodule PhoenixMinimalWeb.Router do
  use PhoenixMinimalWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", PhoenixMinimalWeb do
    pipe_through(:api)

    get("/users", UserController, :index)
    get("/users/:id", UserController, :show)
    post("/users", UserController, :create)
  end
end
