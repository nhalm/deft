import Config

# Production configuration

# Start the HTTP listener when running as a release.
# Without this, the release binary won't start the Phoenix endpoint.
config :deft, DeftWeb.Endpoint,
  server: true,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"]
