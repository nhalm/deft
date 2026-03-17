defmodule Deft.Eval.Actor.ContinuationTest do
  use ExUnit.Case, async: false

  alias Deft.{Config, Provider, Message}
  alias Deft.Message.Text
  alias Deft.Agent.SystemPrompt

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.90

  # Test scenarios with different contexts
  @scenarios [
    %{
      name: "debugging",
      observations_path: "test/eval/fixtures/observation_sets/debugging_context.txt",
      continuation_hint:
        "You were debugging a compilation error in `lib/auth/token.ex`. Your last action was editing that file to add the `verify_token/1` function. The user asked you to check if the pattern matching is correct.",
      tail_messages: [
        %{role: :assistant, text: "I'll add the verify_token function now."},
        %{role: :user, text: "I'm getting a pattern match error on line 45."},
        %{
          role: :assistant,
          text: "Let me check that line. I'll read the file to see the issue."
        }
      ],
      user_prompt: "Can you check if the pattern matching is correct?",
      expected_keywords: ["pattern", "match", "token", "verify"]
    },
    %{
      name: "feature_implementation",
      observations_path: "test/eval/fixtures/observation_sets/feature_implementation_context.txt",
      continuation_hint:
        "You were implementing rate limiting middleware for API endpoints. Your last action was creating the RateLimiter module with basic token bucket logic. The user asked you to add the plug implementation.",
      tail_messages: [
        %{role: :assistant, text: "I've created the basic token bucket structure."},
        %{role: :user, text: "Now we need to integrate it as a Plug."},
        %{role: :assistant, text: "Good idea. I'll add the Plug behaviour implementation."}
      ],
      user_prompt: "Add the plug implementation",
      expected_keywords: ["plug", "rate", "limit", "middleware"]
    }
  ]

  setup_all do
    # Register Anthropic provider for LLM calls
    :ok = Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
    :ok
  end

  describe "Actor continuation after trimming" do
    @tag timeout: 600_000
    test "continues naturally without greeting and references current task" do
      # Run iterations for each scenario
      IO.puts("\n[Running Actor continuation eval - #{@iterations} iterations per scenario]")

      all_results =
        Enum.flat_map(@scenarios, fn scenario ->
          IO.puts("\nScenario: #{scenario.name}")
          run_scenario_iterations(scenario)
        end)

      # Calculate overall pass rate
      total_iterations = length(all_results)
      passed_count = Enum.count(all_results, & &1.passed)
      pass_rate = passed_count / total_iterations

      # Report results
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Actor Continuation Eval")
      IO.puts(String.duplicate("=", 70))
      IO.puts("Pass rate: #{passed_count}/#{total_iterations} (#{trunc(pass_rate * 100)}%)")

      IO.puts("Threshold: #{trunc(@pass_threshold * 100)}%")

      if pass_rate >= @pass_threshold do
        IO.puts("Status: ✓ PASS")
      else
        IO.puts("Status: ✗ FAIL")
        IO.puts("\nFailed iterations:")

        all_results
        |> Enum.with_index(1)
        |> Enum.reject(fn {result, _} -> result.passed end)
        |> Enum.each(fn {result, idx} ->
          IO.puts("\n  Iteration #{idx} (scenario: #{result.scenario}):")
          IO.puts("    Reason: #{result.failure_reason}")

          IO.puts("    Response (first 200 chars): #{String.slice(result.response, 0..199)}...")
        end)
      end

      IO.puts(String.duplicate("=", 70))

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             """
             Actor continuation eval failed: #{passed_count}/#{total_iterations} (#{trunc(pass_rate * 100)}%) < #{trunc(@pass_threshold * 100)}%

             Expected: Actor should continue naturally after message trimming without greeting.
             The Actor should reference the current task and not behave as if the conversation just started.
             """
    end
  end

  # Run iterations for a single scenario
  defp run_scenario_iterations(scenario) do
    # Load observations
    observations = File.read!(scenario.observations_path)

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

    Enum.map(1..@iterations, fn iteration ->
      IO.write("  Iteration #{iteration}/#{@iterations}... ")
      result = run_single_iteration(scenario, observations, config)

      status = if result.passed, do: "✓", else: "✗"
      IO.puts("#{status}")

      Map.put(result, :scenario, scenario.name)
    end)
  end

  # Run a single iteration of the eval
  defp run_single_iteration(scenario, observations, config) do
    # Build context with observations, continuation hint, and tail messages
    messages =
      build_continuation_context(
        observations,
        scenario.continuation_hint,
        scenario.tail_messages,
        scenario.user_prompt,
        config
      )

    # Get tools (empty for this eval - we just want a text response)
    tools = []

    # Call provider
    provider_module = Deft.Provider.Anthropic

    case provider_module.stream(messages, tools, config) do
      {:ok, stream_ref} ->
        # Collect response
        response = collect_stream_response(stream_ref)

        # Check response quality
        checks = %{
          no_greeting: check_no_greeting(response),
          references_task: check_references_task(response, scenario.expected_keywords),
          not_too_short: String.length(response) >= 50
        }

        passed = Enum.all?(Map.values(checks))

        failure_reason =
          cond do
            not checks.no_greeting ->
              "Response contains a greeting (should continue mid-conversation)"

            not checks.references_task ->
              "Response does not reference the current task (expected keywords: #{inspect(scenario.expected_keywords)})"

            not checks.not_too_short ->
              "Response is too short (#{String.length(response)} chars)"

            true ->
              nil
          end

        %{passed: passed, response: response, failure_reason: failure_reason}

      {:error, reason} ->
        %{passed: false, response: "", failure_reason: "Provider error: #{inspect(reason)}"}
    end
  end

  # Build context simulating mid-conversation after trimming
  defp build_continuation_context(
         observations,
         continuation_hint,
         tail_messages,
         user_prompt,
         config
       ) do
    # System prompt
    system_prompt_text = SystemPrompt.build(config)

    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [%Text{text: system_prompt_text}],
      timestamp: DateTime.utc_now()
    }

    # Observation message
    obs_message = build_observation_message(observations)

    # Continuation hint message (injected by Observer to prevent "fresh start" behavior)
    continuation_message = %Message{
      id: "continuation_hint",
      role: :user,
      content: [%Text{text: continuation_hint}],
      timestamp: DateTime.utc_now()
    }

    # Tail messages (last few messages before current prompt)
    tail_message_structs =
      Enum.with_index(tail_messages, 1)
      |> Enum.map(fn {msg, idx} ->
        %Message{
          id: "tail_#{idx}",
          role: msg.role,
          content: [%Text{text: msg.text}],
          timestamp: DateTime.utc_now()
        }
      end)

    # Current user prompt
    current_prompt = %Message{
      id: "user_prompt",
      role: :user,
      content: [%Text{text: user_prompt}],
      timestamp: DateTime.utc_now()
    }

    [system_message, obs_message, continuation_message] ++
      tail_message_structs ++ [current_prompt]
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

  # Check that response does not contain greetings
  defp check_no_greeting(response) do
    response_lower = String.downcase(response)

    # Common greeting patterns
    greetings = [
      "hello",
      "hi there",
      "hi!",
      "hey there",
      "good morning",
      "good afternoon",
      "good evening",
      "greetings",
      # Check for greetings at start of response
      ~r/^(hello|hi|hey|greetings)/i,
      # Check for "nice to meet you" patterns
      ~r/nice to (meet|see) you/i
    ]

    # Response should not contain any greeting patterns
    not Enum.any?(greetings, fn greeting ->
      case greeting do
        %Regex{} = regex -> Regex.match?(regex, response_lower)
        string -> String.contains?(response_lower, string)
      end
    end)
  end

  # Check that response references the current task
  defp check_references_task(response, expected_keywords) do
    response_lower = String.downcase(response)

    # Should mention at least 2 of the expected keywords
    keyword_matches =
      Enum.count(expected_keywords, fn keyword ->
        String.contains?(response_lower, String.downcase(keyword))
      end)

    keyword_matches >= 2
  end
end
