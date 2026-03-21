defmodule Deft.Eval.Helpers do
  @moduledoc """
  Helper functions for evaluation tests.

  Provides utilities for LLM-as-judge evaluations and fixture loading.
  """

  alias Deft.Provider.Anthropic
  alias Deft.Provider.Event.{TextDelta, Done, Error}

  @doc """
  Calls an LLM as a judge for evaluation purposes.

  Makes a streaming request to the Anthropic API with the provided prompt and
  collects all text output into a single judgment string.

  ## Parameters

  - `prompt` - The judge prompt (string)
  - `config` - Optional configuration map (defaults to empty map)

  ## Configuration Options

  - `:model` - Model to use (default: "claude-sonnet-4")
  - `:max_tokens` - Maximum tokens in response (default: 4096)
  - `:temperature` - Temperature setting (default: 1.0)
  - `:timeout` - Timeout in milliseconds (default: 30_000)

  ## Returns

  - `{:ok, judgment}` - The collected text judgment
  - `{:error, reason}` - Error occurred during streaming

  ## Examples

      iex> prompt = "Is this code correct? [code snippet]"
      iex> {:ok, judgment} = call_llm_judge(prompt)
      iex> judgment
      "Yes, the code is correct because..."

      iex> {:ok, judgment} = call_llm_judge(prompt, %{model: "claude-haiku-4.5"})
      iex> judgment
      "Yes, the code is correct..."

  ## Environment

  Requires `ANTHROPIC_API_KEY` environment variable.
  """
  def call_llm_judge(prompt, config \\ %{}) when is_binary(prompt) and is_map(config) do
    # Build a simple message with the prompt
    messages = [
      %Deft.Message{
        id: generate_id(),
        role: :user,
        content: [%Deft.Message.Text{text: prompt}],
        timestamp: DateTime.utc_now()
      }
    ]

    # Start the stream
    case Anthropic.stream(messages, [], config) do
      {:ok, stream_ref} ->
        # Collect events from the stream
        timeout = Map.get(config, :timeout, 30_000)
        collect_judgment(stream_ref, "", timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Collect text deltas from streaming events
  defp collect_judgment(stream_ref, accumulated, timeout) do
    receive do
      {:provider_event, %TextDelta{delta: text}} ->
        # Accumulate text and continue collecting
        collect_judgment(stream_ref, accumulated <> text, timeout)

      {:provider_event, %Done{}} ->
        # Stream complete - return accumulated text
        {:ok, accumulated}

      {:provider_event, %Error{message: message}} ->
        # Error occurred
        {:error, message}
    after
      timeout ->
        # Timeout - cancel stream and return error
        Anthropic.cancel_stream(stream_ref)
        {:error, :timeout}
    end
  end

  # Generate a simple unique ID for messages
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
