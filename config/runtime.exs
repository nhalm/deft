import Config

# Runtime configuration (loaded at runtime, not compile time)
# Note: .env loading happens in Deft.Application.start/2 via Dotenvy

# Read PORT from environment, default to 4000
port = String.to_integer(System.get_env("PORT") || "4000")

# Generate SECRET_KEY_BASE if not set (Deft is a local tool, not a web service)
secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    :crypto.strong_rand_bytes(64) |> Base.encode64()

# Note: ANTHROPIC_API_KEY validation is deferred to LLM-using commands (see Deft.CLI.verify_api_key/0)
# This allows non-LLM commands (--help, --version, config, issue list) to work without an API key

# Read LOG_LEVEL from environment, default to "info"
log_level = System.get_env("LOG_LEVEL", "info") |> String.to_atom()

config :logger, level: log_level

config :deft, DeftWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: secret_key_base
