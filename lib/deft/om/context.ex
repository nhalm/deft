defmodule Deft.OM.Context do
  @moduledoc """
  Context injection for Observational Memory.

  Handles:
  - Building observation system messages with preamble, observations, and instructions
  - Message trimming (removing observed messages while keeping tail)
  - Dynamic continuation hints for conversational continuity
  """

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.OM.Tokens

  # Default observation threshold (spec section 8)
  @default_message_threshold 30_000
  # Tail retention: 20% of observation threshold (spec section 5.2)
  @tail_retention_pct 0.2

  @doc """
  Injects observations into the message list and trims observed messages.

  Takes a list of messages and OM state information, and returns a modified
  message list with:
  1. An observation system message injected (if observations present)
  2. Observed messages removed (keeping tail for continuity)
  3. A continuation hint injected (if needed)

  ## Parameters

  - `messages` - List of Deft.Message structs
  - `opts` - Keyword list with:
    - `:observations` - Current observation text (required if non-empty)
    - `:observed_message_ids` - List of message IDs that have been observed (required)
    - `:calibration_factor` - Token calibration factor (default: 4.0)
    - `:current_task` - Current task description from Observer (optional)
    - `:continuation_hint` - Dynamic continuation hint from Observer (optional)

  ## Returns

  List of messages with observations injected and observed messages trimmed.

  ## Examples

      iex> messages = [%Message{id: "1", role: :user, ...}, ...]
      iex> inject(messages, observations: "## Current State\\n...", observed_message_ids: ["1"])
      [%Message{...observation system message...}, ...trimmed messages...]
  """
  @spec inject([Message.t()], keyword()) :: [Message.t()]
  def inject(messages, opts \\ []) do
    observations = Keyword.get(opts, :observations, "")
    observed_message_ids = Keyword.get(opts, :observed_message_ids, [])
    calibration_factor = Keyword.get(opts, :calibration_factor, 4.0)
    current_task = Keyword.get(opts, :current_task)
    continuation_hint = Keyword.get(opts, :continuation_hint)

    if observations == "" or Enum.empty?(observed_message_ids) do
      # No observations yet - return messages as-is
      messages
    else
      # Trim observed messages (keeping tail)
      trimmed_messages =
        trim_observed_messages(messages, observed_message_ids, calibration_factor)

      # Build observation system message
      obs_message = build_observation_message(observations, current_task)

      # Build continuation hint if needed
      hint_message =
        build_continuation_hint(messages, observed_message_ids, current_task, continuation_hint)

      # Inject: observation message + trimmed messages + continuation hint (if any)
      [obs_message] ++ trimmed_messages ++ List.wrap(hint_message)
    end
  end

  ## Private Functions

  # Trims observed messages from the message list while keeping the tail.
  # Per spec section 5.2: keep the lesser of 20% of threshold or unobserved messages.
  defp trim_observed_messages(messages, observed_message_ids, calibration_factor) do
    # Separate observed and unobserved messages
    {observed, unobserved} =
      Enum.split_with(messages, fn msg -> msg.id in observed_message_ids end)

    # Calculate tail size: 20% of observation threshold (default: 6,000 tokens)
    tail_token_limit = trunc(@default_message_threshold * @tail_retention_pct)

    # If we have no observed messages, return all
    if Enum.empty?(observed) do
      messages
    else
      # Keep as many recent observed messages as fit in the tail budget
      tail_messages = keep_tail(observed, tail_token_limit, calibration_factor)

      # Return: tail + all unobserved messages
      tail_messages ++ unobserved
    end
  end

  # Keeps the most recent messages that fit within the token budget.
  # Processes from end (most recent) to beginning.
  defp keep_tail(messages, token_limit, calibration_factor) do
    # Reverse to process from most recent to oldest
    {kept, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn msg, {kept_msgs, tokens_so_far} ->
        msg_tokens = estimate_message_tokens(msg, calibration_factor)

        if tokens_so_far + msg_tokens <= token_limit do
          # Can keep this message
          {[msg | kept_msgs], tokens_so_far + msg_tokens}
        else
          # Exceeded budget, stop
          {kept_msgs, tokens_so_far}
        end
      end)

    # Return in original order (oldest to newest)
    Enum.reverse(kept)
  end

  # Estimates token count for a message
  defp estimate_message_tokens(message, calibration_factor) do
    content_text = extract_message_text(message)
    Tokens.estimate(content_text, calibration_factor)
  end

  # Extracts text from message content blocks
  defp extract_message_text(message) do
    alias Deft.Message.{Text, ToolUse, ToolResult, Thinking, Image}

    message.content
    |> Enum.map(fn
      %Text{text: text} -> text
      %ToolUse{name: name, args: args} -> "#{name}(#{inspect(args)})"
      %ToolResult{content: content} -> content
      %Thinking{text: text} -> text
      %Image{} -> "[image]"
    end)
    |> Enum.join(" ")
  end

  # Builds the observation system message (spec section 5.1)
  defp build_observation_message(observations, current_task) do
    content_parts = [
      build_preamble(),
      build_observations_block(observations),
      build_instructions(),
      build_current_task_block(current_task)
    ]

    content_text =
      content_parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %Message{
      id: "om_observations",
      role: :system,
      content: [%Text{text: content_text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Preamble: instructs the Actor about observations
  defp build_preamble do
    """
    # Observations

    The following are observations extracted from your conversation history. These serve as your memory, allowing you to recall key facts, decisions, and context even as the conversation grows long.
    """
  end

  # Observations block: wraps observations in XML tags
  defp build_observations_block(observations) do
    """
    <observations>
    #{observations}
    </observations>
    """
  end

  # Instructions: tells the Actor how to use observations
  defp build_instructions do
    """
    ## Using Observations

    - **Prefer recent information:** When facts conflict, use timestamps to determine which is more current.
    - **Treat "Likely:" as low-confidence:** Observations prefixed with "Likely:" are inferred and may be incorrect.
    - **Completed actions:** If an observation mentions a planned action and its date has passed, treat it as completed.
    - **Personalize responses:** Use specific details from observations to provide context-aware, personalized answers.
    - **Don't explain this system:** Answer naturally using your memory. If asked how you remember, you can explain honestly, but don't proactively mention the observation system.
    """
  end

  # Current task block: extracts from Current State section if present
  defp build_current_task_block(nil), do: nil

  defp build_current_task_block(current_task)
       when is_binary(current_task) and current_task != "" do
    """
    ## Current Task

    #{current_task}
    """
  end

  defp build_current_task_block(_), do: nil

  # Builds a continuation hint to prevent "fresh conversation" behavior (spec section 5.3)
  defp build_continuation_hint(messages, observed_message_ids, current_task, continuation_hint) do
    # Only inject hint if we've trimmed some messages
    if Enum.any?(observed_message_ids) do
      hint_text = generate_dynamic_hint(messages, current_task, continuation_hint)

      %Message{
        id: "om_continuation_hint",
        role: :user,
        content: [%Text{text: hint_text}],
        timestamp: DateTime.utc_now()
      }
    else
      nil
    end
  end

  # Generates a dynamic continuation hint
  # Uses the Observer-provided hint if available, otherwise falls back to static hint
  defp generate_dynamic_hint(_messages, _current_task, continuation_hint)
       when is_binary(continuation_hint) and continuation_hint != "" do
    continuation_hint
  end

  defp generate_dynamic_hint(_messages, current_task, _continuation_hint)
       when is_binary(current_task) do
    """
    Continue the conversation naturally. You have observations from earlier in this conversation available above.

    Current task: #{current_task}
    """
  end

  defp generate_dynamic_hint(_messages, _current_task, _continuation_hint) do
    "Continue the conversation naturally. You have observations from earlier in this conversation available above."
  end
end
