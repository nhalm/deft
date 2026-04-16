import Config

# Load .env before reading any env vars
if File.exists?(".env") do
  ".env"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(String.trim(key), String.trim(value))
      _ -> :ok
    end
  end)
end

# Read PORT from environment, default to 4000
port = String.to_integer(System.get_env("PORT") || "4000")

# Generate SECRET_KEY_BASE if not set (Deft is a local tool, not a web service)
secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    :crypto.strong_rand_bytes(64) |> Base.encode64()

# ANTHROPIC_API_KEY is validated lazily by Deft.CLI.verify_api_key/0 when LLM commands run.
# Non-LLM commands (--help, --version, config, issue list) work without an API key.

# Read LOG_LEVEL from environment, default to "info"
# Don't override test environment default (:warning in config/test.exs)
if config_env() != :test do
  log_level_str = System.get_env("LOG_LEVEL", "info")

  unless log_level_str in ~w(debug info warning error) do
    raise """
    Invalid LOG_LEVEL: #{inspect(log_level_str)}

    Valid values: debug | info | warning | error
    """
  end

  log_level = String.to_atom(log_level_str)
  config :logger, level: log_level
end

config :deft, DeftWeb.Endpoint,
  http: [port: port, ip: {0, 0, 0, 0}],
  secret_key_base: secret_key_base
