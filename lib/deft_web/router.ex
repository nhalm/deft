defmodule DeftWeb.Router do
  @moduledoc """
  Phoenix Router for Deft web UI.

  Defines routes for the chat interface and session picker.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {DeftWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", DeftWeb do
    pipe_through(:browser)

    live("/", ChatLive)
    live("/sessions", SessionsLive)
  end
end
