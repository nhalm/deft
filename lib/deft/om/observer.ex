defmodule Deft.OM.Observer do
  @moduledoc """
  Observer LLM task for extracting structured observations from messages.

  The Observer is not a persistent process but a function invoked as a Task
  when State needs to extract observations. It:
  1. Formats unobserved messages
  2. Truncates existing observations to fit token budget
  3. Calls the LLM with Observer system prompt
  4. Parses the result using section-aware rules
  5. Returns structured data back to State
  """

  require Logger

  alias Deft.{Config, Message, Provider}
  alias Deft.Message.{Text, ToolUse, ToolResult, Thinking, Image}
  alias Deft.OM.Tokens
  alias Deft.OM.Observer.{Parse, Prompt}
  alias Deft.Provider.Event.{TextDelta, Done, Error, Usage}

  @doc """
  Runs the Observer extraction task.

  ## Parameters

  - `session_id` - Session identifier for logging
  - `config` - Deft.Config struct with model and provider configuration
  - `messages` - List of unobserved Deft.Message structs
  - `existing_observations` - Current observations text (will be truncated)
  - `calibration_factor` - Token estimation calibration factor

  ## Returns

  A map with:
  - `:observations` - Extracted observation text
  - `:message_ids` - IDs of messages that were observed
  - `:message_tokens` - Token count of the messages that were observed
  - `:current_task` - Current task description (if present)
  - `:continuation_hint` - Dynamic continuation hint (if present)
  - `:usage` - Usage data from provider (%{input_tokens:, output_tokens:}) or nil

  ## Examples

      iex> result = Deft.OM.Observer.run(session_id, config, messages, "", 4.0)
      iex> is_binary(result.observations)
      true
      iex> is_list(result.message_ids)
      true
  """
  @spec run(String.t(), Config.t(), [Message.t()], String.t(), float()) ::
          %{
            observations: String.t(),
            message_ids: [String.t()],
            message_tokens: integer(),
            current_task: String.t() | nil,
            continuation_hint: String.t() | nil,
            usage: %{input_tokens: integer(), output_tokens: integer()} | nil
          }
  def run(session_id, config, messages, existing_observations, calibration_factor) do
    Logger.debug(
      "#{log_prefix(session_id)} Starting observation extraction for #{length(messages)} messages"
    )

    # Prepare input for Observer
    llm_messages = prepare_llm_messages(existing_observations, messages, config)

    # Execute observation extraction
    case execute_observation(session_id, config, llm_messages) do
      {:ok, response_text, usage} ->
        process_observation_result(
          session_id,
          response_text,
          usage,
          messages,
          calibration_factor
        )

      {:error, reason} ->
        Logger.warning("#{log_prefix(session_id)} Observation failed: #{inspect(reason)}")
        empty_result(messages, calibration_factor)
    end
  end

  ## Private Functions

  defp prepare_llm_messages(existing_observations, messages, config) do
    # Format messages for Observer input (spec section 3.3)
    formatted_messages = Prompt.format_messages(messages)

    # Truncate existing observations to configured token budget (spec section 3.2)
    truncated_observations =
      Prompt.truncate_observations(existing_observations, config.om_previous_observer_tokens)

    # Build the user message with truncated observations + new messages
    user_content = build_user_message(truncated_observations, formatted_messages)

    # Create message structs for LLM call
    system_message = %Message{
      id: generate_message_id(),
      role: :system,
      content: [%Text{text: Prompt.system()}],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: user_content}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  defp execute_observation(session_id, config, llm_messages) do
    # Get provider module (use configured om.observer_provider)
    case Provider.Registry.resolve(config.om_observer_provider, config.om_observer_model) do
      {:ok, {provider_module, _model_config}} ->
        # Call LLM with Observer prompt
        llm_config = %{
          model: config.om_observer_model,
          temperature: config.om_observer_temperature,
          max_tokens: 16_000
        }

        call_llm_sync(provider_module, llm_messages, llm_config)

      {:error, reason} ->
        Logger.error("#{log_prefix(session_id)} Failed to resolve provider: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_observation_result(session_id, response_text, usage, messages, calibration_factor) do
    # Parse the Observer output
    case Parse.parse_output(response_text) do
      {:ok, parsed} ->
        build_success_result(session_id, parsed, usage, messages, calibration_factor)

      {:error, reason} ->
        Logger.warning("#{log_prefix(session_id)} Failed to parse output: #{inspect(reason)}")
        empty_result(messages, calibration_factor)
    end
  end

  defp build_success_result(session_id, parsed, usage, messages, calibration_factor) do
    # Calculate message tokens
    message_tokens = calculate_message_tokens(messages, calibration_factor)
    message_ids = Enum.map(messages, & &1.id)

    Logger.debug(
      "#{log_prefix(session_id)} Extracted observations (#{Tokens.estimate(parsed.observations, calibration_factor)} tokens) from #{message_tokens} tokens of messages"
    )

    %{
      observations: parsed.observations,
      message_ids: message_ids,
      message_tokens: message_tokens,
      current_task: parsed.current_task,
      continuation_hint: parsed.continuation_hint,
      usage: usage
    }
  end

  defp build_user_message("", formatted_messages) do
    """
    New messages to observe:

    #{formatted_messages}
    """
  end

  defp build_user_message(existing_observations, formatted_messages) do
    """
    Existing observations (for deduplication):

    #{existing_observations}

    New messages to observe:

    #{formatted_messages}
    """
  end

  defp generate_message_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp call_llm_sync(provider_module, messages, config) do
    # Make streaming call and collect text response
    case provider_module.stream(messages, [], config) do
      {:ok, stream_ref} ->
        collect_stream_text(stream_ref, 120_000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_stream_text(stream_ref, timeout) do
    state = %{
      acc: "",
      usage: nil,
      start_time: :os.system_time(:millisecond),
      timeout: timeout
    }

    collect_stream_text_loop(stream_ref, state)
  end

  defp collect_stream_text_loop(stream_ref, state) do
    remaining_timeout = calculate_remaining_timeout(state)

    receive do
      {:provider_event, event} ->
        handle_provider_event(stream_ref, event, state)
    after
      remaining_timeout ->
        handle_stream_timeout(stream_ref)
    end
  end

  defp calculate_remaining_timeout(state) do
    elapsed = :os.system_time(:millisecond) - state.start_time
    max(0, state.timeout - elapsed)
  end

  defp handle_provider_event(stream_ref, %TextDelta{delta: delta}, state) do
    new_state = %{state | acc: state.acc <> delta}
    collect_stream_text_loop(stream_ref, new_state)
  end

  defp handle_provider_event(
         stream_ref,
         %Usage{input: input_tokens, output: output_tokens},
         state
       ) do
    new_usage = merge_usage(state.usage, input_tokens, output_tokens)
    new_state = %{state | usage: new_usage}
    collect_stream_text_loop(stream_ref, new_state)
  end

  defp handle_provider_event(_stream_ref, %Done{}, state) do
    {:ok, state.acc, state.usage}
  end

  defp handle_provider_event(_stream_ref, %Error{message: msg}, _state) do
    {:error, msg}
  end

  defp handle_provider_event(stream_ref, _other, state) do
    # Ignore other events (tool calls, thinking, etc.)
    collect_stream_text_loop(stream_ref, state)
  end

  defp handle_stream_timeout(stream_ref) do
    # Cancel stream on timeout
    if is_pid(stream_ref) and Process.alive?(stream_ref) do
      Process.exit(stream_ref, :timeout)
    end

    {:error, :timeout}
  end

  defp merge_usage(nil, input_tokens, output_tokens) do
    %{input_tokens: input_tokens, output_tokens: output_tokens}
  end

  defp merge_usage(existing, input_tokens, output_tokens) do
    %{
      input_tokens: existing.input_tokens + input_tokens,
      output_tokens: existing.output_tokens + output_tokens
    }
  end

  defp calculate_message_tokens(messages, calibration_factor) do
    messages
    |> Enum.map(fn msg ->
      # Calculate token count for each message by estimating content size
      content_text = extract_message_text(msg)
      Tokens.estimate(content_text, calibration_factor)
    end)
    |> Enum.sum()
  end

  defp extract_message_text(message) do
    message.content
    |> Enum.map(&content_block_to_text/1)
    |> Enum.join(" ")
  end

  defp content_block_to_text(%Text{text: text}), do: text
  defp content_block_to_text(%ToolUse{name: name, args: args}), do: "#{name}(#{inspect(args)})"
  defp content_block_to_text(%ToolResult{content: content}), do: content
  defp content_block_to_text(%Thinking{text: text}), do: text
  defp content_block_to_text(%Image{}), do: "[image]"

  defp empty_result(messages, calibration_factor) do
    # Return empty observations but still track the messages
    message_tokens = calculate_message_tokens(messages, calibration_factor)
    message_ids = Enum.map(messages, & &1.id)

    %{
      observations: "",
      message_ids: message_ids,
      message_tokens: message_tokens,
      current_task: nil,
      continuation_hint: nil,
      usage: nil
    }
  end

  defp log_prefix(session_id) do
    prefix = String.slice(session_id, 0, 8)
    "[OM:#{prefix}]"
  end
end
