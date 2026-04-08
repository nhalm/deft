import Config

# Configure Phoenix JSON library
config :phoenix, :json_library, Jason

# Configure Phoenix endpoint
config :deft, DeftWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  #  url: [host: "localhost"],
  url: [host: "0.0.0.0"],
  render_errors: [
    formats: [html: DeftWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Deft.PubSub,
  live_view: [signing_salt: "deft_live_view"]

# Configure LiveView
config :deft, :live_view, signing_salt: "deft_live_view_salt"

# Configure esbuild for asset compilation
config :esbuild,
  version: "0.17.11",
  default: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
