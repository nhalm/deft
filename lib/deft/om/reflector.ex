defmodule Deft.OM.Reflector do
  @moduledoc """
  Reflector LLM task for compressing observations when they grow too large.

  The Reflector is not a persistent process but a function invoked as a Task
  when State needs to compress observations. It:
  1. Takes the full active_observations and target size
  2. Calls the LLM with escalating compression levels (0-3)
  3. Retries if output exceeds target size (max 2 LLM calls)
  4. Validates CORRECTION markers survive compression
  5. Returns compressed observations back to State
  """

  require Logger

  alias Deft.{Config, Message, Provider}
  alias Deft.Message.Text
  alias Deft.OM.{Reflector.Prompt, Tokens}
  alias Deft.Provider.Event.{TextDelta, Done, Error, Usage}

  @doc """
  Runs the Reflector compression task.

  ## Parameters

  - `session_id` - Session identifier for logging
  - `config` - Deft.Config struct with model and provider configuration
  - `active_observations` - Current observations text to compress
  - `target_size` - Target token count for compressed output (default 20,000)
  - `calibration_factor` - Token estimation calibration factor

  ## Returns

  A map with:
  - `:compressed_observations` - Compressed observation text
  - `:before_tokens` - Token count before compression
  - `:after_tokens` - Token count after compression
  - `:compression_level` - Final compression level used (0-3)
  - `:llm_calls` - Number of LLM calls made
  - `:usage` - Usage data from the final LLM call (%{input_tokens:, output_tokens:}) or nil

  ## Examples

      iex> result = Deft.OM.Reflector.run(session_id, config, observations, 20_000, 4.0)
      iex> is_binary(result.compressed_observations)
      true
      iex> result.llm_calls <= 2
      true
  """
  @spec run(String.t(), Config.t(), String.t(), integer(), float()) ::
          %{
            compressed_observations: String.t(),
            before_tokens: integer(),
            after_tokens: integer(),
            compression_level: integer(),
            llm_calls: integer(),
            usage: %{input_tokens: integer(), output_tokens: integer()} | nil
          }
  def run(session_id, config, active_observations, target_size \\ 20_000, calibration_factor) do
    Logger.debug(
      "#{log_prefix(session_id)} Starting compression with target size #{target_size} tokens"
    )

    before_tokens = Tokens.estimate(active_observations, calibration_factor)

    # Extract CORRECTION markers for post-check
    correction_markers = extract_correction_markers(active_observations)

    # Try compression with escalating levels (max 2 LLM calls)
    context = %{
      session_id: session_id,
      config: config,
      observations: active_observations,
      target_size: target_size,
      calibration_factor: calibration_factor,
      correction_markers: correction_markers
    }

    {compressed, level, llm_calls, usage} = compress_with_retry(context)

    after_tokens = Tokens.estimate(compressed, calibration_factor)

    Logger.debug(
      "#{log_prefix(session_id)} Compressed from #{before_tokens} to #{after_tokens} tokens (level #{level}, #{llm_calls} LLM calls)"
    )

    %{
      compressed_observations: compressed,
      before_tokens: before_tokens,
      after_tokens: after_tokens,
      compression_level: level,
      llm_calls: llm_calls,
      usage: usage
    }
  end

  ## Private Functions

  # Try compression with escalating levels, max 2 LLM calls
  defp compress_with_retry(context) do
    case attempt_compression(context, 0) do
      {:ok, compressed, level, usage} ->
        {compressed, level, 1, usage}

      {:retry, _compressed, level, _usage} ->
        retry_with_next_level(context, level)
    end
  end

  defp retry_with_next_level(context, level) do
    next_level = min(level + 1, 3)

    case attempt_compression(context, next_level) do
      {:ok, compressed, final_level, usage} ->
        {compressed, final_level, 2, usage}

      {:retry, compressed, final_level, usage} ->
        accept_retry_output(context.session_id, compressed, final_level, usage)
    end
  end

  defp accept_retry_output(session_id, compressed, level, usage) do
    Logger.warning(
      "#{log_prefix(session_id)} Level #{level} still exceeds target, accepting output"
    )

    {compressed, level, 2, usage}
  end

  # Attempt compression at a specific level
  defp attempt_compression(context, level) do
    case call_llm_for_compression(
           context.session_id,
           context.config,
           context.observations,
           context.target_size,
           level
         ) do
      {:ok, compressed, usage} ->
        # Validate CORRECTION markers survived
        validated =
          ensure_correction_markers(context.session_id, compressed, context.correction_markers)

        # Check if output is within target
        token_count = Tokens.estimate(validated, context.calibration_factor)

        if token_count <= context.target_size do
          {:ok, validated, level, usage}
        else
          Logger.debug(
            "#{log_prefix(context.session_id)} Level #{level} output (#{token_count} tokens) exceeds target (#{context.target_size} tokens)"
          )

          {:retry, validated, level, usage}
        end

      {:error, reason} ->
        Logger.warning(
          "#{log_prefix(context.session_id)} LLM call failed at level #{level}: #{inspect(reason)}"
        )

        # On error, trigger retry with next compression level
        {:retry, context.observations, level, nil}
    end
  end

  # Make LLM call with specified compression level
  defp call_llm_for_compression(session_id, config, observations, target_size, compression_level) do
    # Build system prompt with compression level
    system_prompt =
      Prompt.system(target_size: target_size, compression_level: compression_level)

    # Create message structs for LLM call
    system_message = %Message{
      id: generate_message_id(),
      role: :system,
      content: [%Text{text: system_prompt}],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: observations}],
      timestamp: DateTime.utc_now()
    }

    # Get provider module (use configured om.reflector_provider)
    case Provider.Registry.resolve(config.om_reflector_provider, config.om_reflector_model) do
      {:ok, {provider_module, _model_config}} ->
        # Call LLM with Reflector prompt
        llm_config = %{
          model: config.om_reflector_model,
          temperature: config.om_reflector_temperature,
          max_tokens: 100_000
        }

        call_llm_sync(provider_module, [system_message, user_message], llm_config)

      {:error, reason} ->
        Logger.error("#{log_prefix(session_id)} Failed to resolve provider: #{inspect(reason)}")
        {:error, reason}
    end
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
      {:provider_event, %TextDelta{delta: delta}} ->
        handle_text_delta(stream_ref, state, delta)

      {:provider_event, %Usage{input: input_tokens, output: output_tokens}} ->
        handle_usage_event(stream_ref, state, input_tokens, output_tokens)

      {:provider_event, %Done{}} ->
        {:ok, state.acc, state.usage}

      {:provider_event, %Error{message: msg}} ->
        {:error, msg}

      {:provider_event, _other} ->
        collect_stream_text_loop(stream_ref, state)
    after
      remaining_timeout ->
        handle_timeout(stream_ref)
    end
  end

  defp calculate_remaining_timeout(state) do
    elapsed = :os.system_time(:millisecond) - state.start_time
    max(0, state.timeout - elapsed)
  end

  defp handle_text_delta(stream_ref, state, delta) do
    new_state = %{state | acc: state.acc <> delta}
    collect_stream_text_loop(stream_ref, new_state)
  end

  defp handle_usage_event(stream_ref, state, input_tokens, output_tokens) do
    usage_data = merge_usage(state.usage, input_tokens, output_tokens)
    new_state = %{state | usage: usage_data}
    collect_stream_text_loop(stream_ref, new_state)
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

  defp handle_timeout(stream_ref) do
    if is_pid(stream_ref) and Process.alive?(stream_ref) do
      Process.exit(stream_ref, :timeout)
    end

    {:error, :timeout}
  end

  # Extract all CORRECTION markers from observations
  defp extract_correction_markers(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "CORRECTION:"))
    |> Enum.map(&String.trim/1)
  end

  # Ensure all CORRECTION markers from input appear in output
  # If any are missing, append them to the appropriate section
  defp ensure_correction_markers(session_id, compressed, correction_markers) do
    missing_markers =
      Enum.reject(correction_markers, fn marker ->
        String.contains?(compressed, marker)
      end)

    if Enum.empty?(missing_markers) do
      compressed
    else
      Logger.warning(
        "#{log_prefix(session_id)} #{length(missing_markers)} CORRECTION markers missing, appending"
      )

      append_missing_corrections(compressed, missing_markers)
    end
  end

  # Append missing CORRECTION markers to the end of the appropriate section
  defp append_missing_corrections(compressed, missing_markers) do
    # Try to find where to insert - look for Session History section as fallback
    # If no sections found, append to end
    section_pattern = ~r/(## Session History.*?)(?=\n## |$)/s

    case Regex.run(section_pattern, compressed, capture: :all) do
      [_, section_content] ->
        # Append to Session History section
        correction_lines = Enum.join(missing_markers, "\n")

        new_section = section_content <> "\n" <> correction_lines

        String.replace(compressed, section_content, new_section, global: false)

      nil ->
        # No Session History section - append to end
        correction_lines = Enum.join(missing_markers, "\n")
        compressed <> "\n\n" <> correction_lines
    end
  end

  defp generate_message_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp log_prefix(session_id) do
    prefix = String.slice(session_id, 0, 8)
    "[OM:#{prefix}]"
  end
end
