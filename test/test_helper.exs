# Start the application to ensure all supervisors and registries are running
{:ok, _} = Application.ensure_all_started(:deft)

# Register providers for tests
:ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

ExUnit.start(capture_log: true)

# Exclude eval and integration tests by default
ExUnit.configure(exclude: [:eval, :integration])
