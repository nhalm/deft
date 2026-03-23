import Config

# Runtime configuration (loaded at runtime, not compile time)

# Generate a secret key base for production if not set
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :deft, DeftWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4000],
    secret_key_base: secret_key_base
end
