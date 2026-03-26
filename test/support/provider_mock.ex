defmodule Deft.ProviderMock do
  @moduledoc """
  Test provider that always fails stream calls.

  Used in Foreman tests to avoid depending on ANTHROPIC_API_KEY presence.
  Pass `provider_module: Deft.ProviderMock` in the Foreman config.
  """

  def stream(_messages, _tools, _config) do
    {:error, :test_provider}
  end

  def model_config(_model_name) do
    %{max_tokens: 8192}
  end
end
