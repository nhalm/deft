import Config

# Development configuration

# For development, we enable code reloading and debugging
config :deft, DeftWeb.Endpoint,
  server: true,
  # Binding to loopback ipv4 address prevents access from other machines.
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_at_least_64_bytes_long_for_development_only_do_not_use_in_production",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]

# Watch static and templates for browser reloading.
config :deft, DeftWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/deft_web/(live|views|components)/.*(ex|heex)$",
      ~r"lib/deft_web.ex$"
    ]
  ]
