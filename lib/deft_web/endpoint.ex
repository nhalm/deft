defmodule DeftWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for Deft web UI.

  Serves on localhost:4000 (configurable), provides LiveView socket at /live,
  and handles static asset serving.
  """

  use Phoenix.Endpoint, otp_app: :deft

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_deft_key",
    signing_salt: "deft_session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Serve static files from the "priv/static" directory
  plug(Plug.Static,
    at: "/",
    from: :deft,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  # Router is plugged separately - will be created in next work item
  if Code.ensure_loaded?(DeftWeb.Router) do
    plug(DeftWeb.Router)
  end
end
