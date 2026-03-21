defmodule PhoenixMinimalWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_minimal

  @session_options [
    store: :cookie,
    key: "_phoenix_minimal_key",
    signing_salt: "test_salt",
    same_site: "Lax"
  ]

  plug(Plug.Session, @session_options)
  plug(PhoenixMinimalWeb.Router)
end
