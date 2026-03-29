import Config

# Test configuration

# Keep tests quiet — only show log output for failing tests
config :logger, level: :warning

# Don't auto-start Issues in tests - tests start it with specific file paths
config :deft, auto_start_issues: false

# Configure the endpoint for tests
config :deft, DeftWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_for_testing_only_do_not_use_in_production_key",
  server: false
