defmodule Deft.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias Deft.Provider.Registry

  # Mock provider module for testing
  defmodule MockProvider do
    @behaviour Deft.Provider

    @impl true
    def stream(_messages, _tools, _config), do: {:ok, self()}

    @impl true
    def cancel_stream(_ref), do: :ok

    @impl true
    def parse_event(_event), do: :skip

    @impl true
    def format_messages(_messages), do: []

    @impl true
    def format_tools(_tools), do: []

    @impl true
    def model_config("test-model-1") do
      %{
        context_window: 100_000,
        max_output: 4096,
        input_price_per_mtok: 1.0,
        output_price_per_mtok: 5.0
      }
    end

    def model_config("test-model-2") do
      %{
        context_window: 200_000,
        max_output: 8192,
        input_price_per_mtok: 2.0,
        output_price_per_mtok: 10.0
      }
    end

    def model_config(_unknown), do: {:error, :unknown_model}
  end

  setup do
    # Start the Registry if not already started
    case GenServer.whereis(Registry) do
      nil ->
        {:ok, _pid} = start_supervised(Registry)

      _pid ->
        :ok
    end

    :ok
  end

  describe "register/2" do
    test "registers a provider successfully" do
      assert :ok = Registry.register("mock", MockProvider)
    end

    test "allows overwriting an existing provider" do
      assert :ok = Registry.register("mock", MockProvider)
      assert :ok = Registry.register("mock", MockProvider)
    end
  end

  describe "resolve/2" do
    setup do
      Registry.register("mock", MockProvider)
      :ok
    end

    test "resolves a registered provider with valid model" do
      assert {:ok, {module, config}} = Registry.resolve("mock", "test-model-1")
      assert module == MockProvider
      assert config.context_window == 100_000
      assert config.max_output == 4096
      assert config.input_price_per_mtok == 1.0
      assert config.output_price_per_mtok == 5.0
    end

    test "resolves different models from same provider" do
      assert {:ok, {_module, config1}} = Registry.resolve("mock", "test-model-1")
      assert {:ok, {_module, config2}} = Registry.resolve("mock", "test-model-2")
      assert config1.context_window == 100_000
      assert config2.context_window == 200_000
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Registry.resolve("unknown", "test-model-1")
    end

    test "returns error for unknown model" do
      assert {:error, :unknown_model} = Registry.resolve("mock", "unknown-model")
    end
  end

  describe "resolve/2 with Anthropic provider" do
    setup do
      Registry.register("anthropic", Deft.Provider.Anthropic)
      :ok
    end

    test "resolves claude-sonnet-4" do
      assert {:ok, {module, config}} = Registry.resolve("anthropic", "claude-sonnet-4")
      assert module == Deft.Provider.Anthropic
      assert config.context_window == 200_000
      assert config.max_output == 16_000
      assert config.input_price_per_mtok == 3.00
      assert config.output_price_per_mtok == 15.00
    end

    test "resolves claude-opus-4" do
      assert {:ok, {module, config}} = Registry.resolve("anthropic", "claude-opus-4")
      assert module == Deft.Provider.Anthropic
      assert config.context_window == 200_000
      assert config.max_output == 32_000
      assert config.input_price_per_mtok == 15.00
      assert config.output_price_per_mtok == 75.00
    end

    test "resolves claude-haiku-4.5" do
      assert {:ok, {module, config}} = Registry.resolve("anthropic", "claude-haiku-4.5")
      assert module == Deft.Provider.Anthropic
      assert config.context_window == 200_000
      assert config.max_output == 8192
      assert config.input_price_per_mtok == 0.80
      assert config.output_price_per_mtok == 4.00
    end

    test "returns error for unsupported model" do
      assert {:error, :unknown_model} = Registry.resolve("anthropic", "gpt-4")
    end
  end
end
