defmodule Deft.Eval.Actor.ObservationUsageTest do
  use ExUnit.Case, async: false

  alias Deft.{Config, Provider, Message}
  alias Deft.Message.Text
  alias Deft.Agent.SystemPrompt

  @moduletag :eval
  @moduletag :expensive

  @fixture_path "test/eval/fixtures/observation_sets/argon2_preference.txt"
  @iterations 20
  @pass_threshold 0.85

  setup_all do
    # Register Anthropic provider for LLM calls
    :ok = Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
    :ok
  end

  setup do
    # Skip if API key not set
    if is_nil(System.get_env("ANTHROPIC_API_KEY")) do
      :skip
    else
      :ok
    end
  end

  describe "Actor observation usage" do
    @tag timeout: 600_000
    test "references observations correctly in response" do
      # Load fixture observations
      observations = File.read!(@fixture_path)

      # Create config
      config = %Config{
        model: "claude-sonnet-4.5",
        provider: "anthropic",
        om_reflector_model: "claude-haiku-4.5",
        turn_limit: 100,
        tool_timeout: 120_000,
        bash_timeout: 120_000,
        om_enabled: true,
        om_observer_model: "claude-haiku-4.5",
        cache_token_threshold: 10_000,
        cache_token_threshold_read: 20_000,
        cache_token_threshold_grep: 8_000,
        cache_token_threshold_ls: 4_000,
        cache_token_threshold_find: 4_000,
        issues_compaction_days: 90
      }

      # Run iterations
      IO.puts("\n[Running Actor observation usage eval - #{@iterations} iterations]")

      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.write("  Iteration #{iteration}/#{@iterations}... ")
          result = run_single_iteration(observations, config)

          status = if result.passed, do: "✓", else: "✗"
          IO.puts("#{status}")

          result
        end)

      # Calculate pass rate
      passed_count = Enum.count(results, & &1.passed)
      pass_rate = passed_count / @iterations

      # Report results
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Actor Observation Usage Eval")
      IO.puts(String.duplicate("=", 70))
      IO.puts("Pass rate: #{passed_count}/#{@iterations} (#{trunc(pass_rate * 100)}%)")
      IO.puts("Threshold: #{trunc(@pass_threshold * 100)}%")

      if pass_rate >= @pass_threshold do
        IO.puts("Status: ✓ PASS")
      else
        IO.puts("Status: ✗ FAIL")
        IO.puts("\nFailed iterations:")

        results
        |> Enum.with_index(1)
        |> Enum.reject(fn {result, _} -> result.passed end)
        |> Enum.each(fn {result, idx} ->
          IO.puts("\n  Iteration #{idx}:")
          IO.puts("    Reason: #{result.failure_reason}")
          IO.puts("    Response (first 200 chars): #{String.slice(result.response, 0..199)}...")
        end)
      end

      IO.puts(String.duplicate("=", 70))

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             """
             Actor observation usage eval failed: #{passed_count}/#{@iterations} (#{trunc(pass_rate * 100)}%) < #{trunc(@pass_threshold * 100)}%

             Expected: Actor should reference argon2 from observations when asked to implement login endpoint.
             The Actor should prefer information from observations over default assumptions (bcrypt).
             """
    end
  end

  # Run a single iteration of the eval
  defp run_single_iteration(observations, config) do
    # Build context with observations
    messages = build_context_with_observations(observations, config)

    # Get tools (empty for this eval - we just want a text response)
    tools = []

    # Call provider
    provider_module = Deft.Provider.Anthropic

    case provider_module.stream(messages, tools, config) do
      {:ok, stream_ref} ->
        # Collect response
        response = collect_stream_response(stream_ref)

        # Check if response references argon2
        passed = check_response_references_argon2(response)

        failure_reason =
          cond do
            not passed and String.contains?(String.downcase(response), "bcrypt") ->
              "Response mentions bcrypt instead of argon2"

            not passed ->
              "Response does not mention argon2"

            true ->
              nil
          end

        %{passed: passed, response: response, failure_reason: failure_reason}

      {:error, reason} ->
        %{passed: false, response: "", failure_reason: "Provider error: #{inspect(reason)}"}
    end
  end

  # Build context with observations injected
  defp build_context_with_observations(observations, config) do
    # Create system prompt
    system_prompt_text = SystemPrompt.build(config)

    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [%Text{text: system_prompt_text}],
      timestamp: DateTime.utc_now()
    }

    # Create observation message using OM.Context format
    obs_message = build_observation_message(observations)

    # Create user prompt
    user_message = %Message{
      id: "user_prompt",
      role: :user,
      content: [%Text{text: "implement the login endpoint"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, obs_message, user_message]
  end

  # Build observation message in the same format as OM.Context
  defp build_observation_message(observations) do
    content = """
    # Observations

    The following are observations extracted from your conversation history. These serve as your memory, allowing you to recall key facts, decisions, and context even as the conversation grows long.

    <observations>
    #{observations}
    </observations>

    ## Using Observations

    - **Prefer recent information:** When facts conflict, use timestamps to determine which is more current.
    - **Treat "Likely:" as low-confidence:** Observations prefixed with "Likely:" are inferred and may be incorrect.
    - **Completed actions:** If an observation mentions a planned action and its date has passed, treat it as completed.
    - **Personalize responses:** Use specific details from observations to provide context-aware, personalized answers.
    - **Don't explain this system:** Answer naturally using your memory. If asked how you remember, you can explain honestly, but don't proactively mention the observation system.
    """

    %Message{
      id: "om_observations",
      role: :system,
      content: [%Text{text: content}],
      timestamp: DateTime.utc_now()
    }
  end

  # Collect the full response from the stream
  defp collect_stream_response(stream_ref) do
    collect_stream_response(stream_ref, "")
  end

  defp collect_stream_response(stream_ref, acc) do
    receive do
      {:provider_event, %Deft.Provider.Event.TextDelta{delta: delta}} ->
        collect_stream_response(stream_ref, acc <> delta)

      {:provider_event, %Deft.Provider.Event.Done{}} ->
        acc

      {:provider_event, %Deft.Provider.Event.Error{message: message}} ->
        raise "Stream error: #{message}"

      # Ignore other events (tool calls, thinking, etc.)
      {:provider_event, _other} ->
        collect_stream_response(stream_ref, acc)
    after
      120_000 ->
        raise "Timeout waiting for stream response"
    end
  end

  # Check if the response references argon2
  defp check_response_references_argon2(response) do
    response_lower = String.downcase(response)

    # Check if argon2 is mentioned
    String.contains?(response_lower, "argon2") or
      String.contains?(response_lower, "argon 2")
  end
end
