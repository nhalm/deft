import Config

# Configure Phoenix JSON library
config :phoenix, :json_library, Jason

# Configure Phoenix endpoint
config :deft, DeftWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: DeftWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Deft.PubSub,
  live_view: [signing_salt: "deft_live_view"]

# Configure LiveView
config :deft, :live_view, signing_salt: "deft_live_view_salt"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
