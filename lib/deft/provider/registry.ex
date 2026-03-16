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

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      providers: %{}
    }

    {:ok, state}
  end
end
