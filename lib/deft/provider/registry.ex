defmodule Deft.Provider.Registry do
  @moduledoc """
  Registry for LLM provider configurations and state.

  Stores provider configs and resolves provider name + model name to module + config.
  This GenServer manages the runtime configuration for all LLM providers.
  """

  use GenServer

  # Client API

  @doc """
  Starts the Provider Registry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a provider with the registry.

  ## Parameters

  - `name` - String identifier for the provider (e.g., "anthropic")
  - `module` - The module implementing the Deft.Provider behaviour

  ## Examples

      iex> Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
      :ok
  """
  def register(name, module) when is_binary(name) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, name, module})
  end

  @doc """
  Resolves a provider name and model name to a provider module and model config.

  ## Parameters

  - `provider_name` - String identifier for the provider (e.g., "anthropic")
  - `model_name` - String identifier for the model (e.g., "claude-sonnet-4")

  ## Returns

  - `{:ok, {module, model_config}}` - Provider found and model config retrieved
  - `{:error, :unknown_provider}` - Provider not registered
  - `{:error, :unknown_model}` - Provider found but model not supported

  ## Examples

      iex> Deft.Provider.Registry.resolve("anthropic", "claude-sonnet-4")
      {:ok, {Deft.Provider.Anthropic, %{context_window: 200_000, ...}}}

      iex> Deft.Provider.Registry.resolve("unknown", "model")
      {:error, :unknown_provider}
  """
  def resolve(provider_name, model_name)
      when is_binary(provider_name) and is_binary(model_name) do
    GenServer.call(__MODULE__, {:resolve, provider_name, model_name})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      providers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, name, module}, _from, state) do
    new_state = put_in(state, [:providers, name], module)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:resolve, provider_name, model_name}, _from, state) do
    case Map.get(state.providers, provider_name) do
      nil ->
        {:reply, {:error, :unknown_provider}, state}

      module ->
        case module.model_config(model_name) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          model_config when is_map(model_config) ->
            {:reply, {:ok, {module, model_config}}, state}
        end
    end
  end
end
