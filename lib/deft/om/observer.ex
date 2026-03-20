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

      iex> result = Deft.OM.Observer.run(config, messages, "", 4.0)
      iex> is_binary(result.observations)
      true
      iex> is_list(result.message_ids)
      true
  """
  @spec run(Config.t(), [Message.t()], String.t(), float()) ::
          %{
            observations: String.t(),
            message_ids: [String.t()],
            message_tokens: integer(),
            current_task: String.t() | nil,
            continuation_hint: String.t() | nil,
            usage: %{input_tokens: integer(), output_tokens: integer()} | nil
          }
  def run(config, messages, existing_observations, calibration_factor) do
    Logger.debug("Observer: Starting observation extraction for #{length(messages)} messages")

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

    # Get provider module (use configured om.observer_provider)
    case Provider.Registry.resolve(config.om_observer_provider, config.om_observer_model) do
      {:ok, {provider_module, _model_config}} ->
        # Call LLM with Observer prompt
        llm_config = %{
          model: config.om_observer_model,
          temperature: config.om_observer_temperature,
          max_tokens: 16_000
        }

        case call_llm_sync(provider_module, [system_message, user_message], llm_config) do
          {:ok, response_text, usage} ->
            # Parse the Observer output
            case Parse.parse_output(response_text) do
              {:ok,
               %{
                 observations: observations,
                 current_task: current_task,
                 continuation_hint: continuation_hint
               }} ->
                # Calculate message tokens
                message_tokens = calculate_message_tokens(messages, calibration_factor)
                message_ids = Enum.map(messages, & &1.id)

                Logger.debug(
                  "Observer: Extracted observations (#{Tokens.estimate(observations, calibration_factor)} tokens) from #{message_tokens} tokens of messages"
                )

                %{
                  observations: observations,
                  message_ids: message_ids,
                  message_tokens: message_tokens,
                  current_task: current_task,
                  continuation_hint: continuation_hint,
                  usage: usage
                }

              {:error, reason} ->
                Logger.warning("Observer: Failed to parse output: #{inspect(reason)}")
                # Return empty observations on parse failure
                empty_result(messages, calibration_factor)
            end

          {:error, reason} ->
            Logger.warning("Observer: LLM call failed: #{inspect(reason)}")
            # Return empty observations on LLM failure
            empty_result(messages, calibration_factor)
        end

      {:error, reason} ->
        Logger.error("Observer: Failed to resolve provider: #{inspect(reason)}")
        # Return empty observations on provider resolution failure
        empty_result(messages, calibration_factor)
    end
  end

  ## Private Functions

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
    collect_stream_text_loop(stream_ref, "", nil, :os.system_time(:millisecond), timeout)
  end

  defp collect_stream_text_loop(stream_ref, acc, usage, start_time, timeout) do
    elapsed = :os.system_time(:millisecond) - start_time
    remaining_timeout = max(0, timeout - elapsed)

    receive do
      {:provider_event, %TextDelta{delta: delta}} ->
        collect_stream_text_loop(stream_ref, acc <> delta, usage, start_time, timeout)

      {:provider_event, %Usage{input: input_tokens, output: output_tokens}} ->
        usage_data =
          case usage do
            nil ->
              %{input_tokens: input_tokens, output_tokens: output_tokens}

            existing ->
              %{
                input_tokens: existing.input_tokens + input_tokens,
                output_tokens: existing.output_tokens + output_tokens
              }
          end

        collect_stream_text_loop(stream_ref, acc, usage_data, start_time, timeout)

      {:provider_event, %Done{}} ->
        {:ok, acc, usage}

      {:provider_event, %Error{message: msg}} ->
        {:error, msg}

      {:provider_event, _other} ->
        # Ignore other events (tool calls, thinking, etc.)
        collect_stream_text_loop(stream_ref, acc, usage, start_time, timeout)
    after
      remaining_timeout ->
        # Cancel stream on timeout
        if is_pid(stream_ref) and Process.alive?(stream_ref) do
          Process.exit(stream_ref, :timeout)
        end

        {:error, :timeout}
    end
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
end
