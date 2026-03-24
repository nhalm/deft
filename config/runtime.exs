import Config

# Runtime configuration (loaded at runtime, not compile time)

# Read PORT from environment, default to 4000
port = String.to_integer(System.get_env("PORT") || "4000")

# Generate SECRET_KEY_BASE if not set (Deft is a local tool, not a web service)
secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    :crypto.strong_rand_bytes(64) |> Base.encode64()

# Validate ANTHROPIC_API_KEY — fail fast on startup if missing (except in test env)
if config_env() != :test and not System.get_env("ANTHROPIC_API_KEY") do
  raise """
  environment variable ANTHROPIC_API_KEY is missing.
  Set it to your Anthropic API key to use Deft.
  """
end

config :deft, DeftWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: secret_key_base
