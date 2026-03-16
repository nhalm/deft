ExUnit.start()

# Exclude eval and integration tests by default
ExUnit.configure(exclude: [:eval, :integration])
