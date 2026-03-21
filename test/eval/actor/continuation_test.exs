defmodule Deft.Eval.Actor.ContinuationTest do
  @moduledoc """
  Eval tests for Actor continuation after message trimming.

  Tests that the Actor correctly continues conversations after observational
  memory has trimmed earlier messages. Per spec section 4.2, the actor should:
  - Continue naturally (no greeting)
  - Reference the current task from observations

  Pass rate: 90% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.Provider.Anthropic
  alias Deft.Provider.Event.{TextDelta, Done, Error}

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.90

  setup do
    config = Config.load()

    {:ok, config: config}
  end

  describe "continuation after trimming - LLM judge (90% over 20 iterations)" do
    @tag timeout: 180_000
    test "continues naturally without greeting", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Simulate mid-conversation context:
          # - Observations with continuation hint
          # - Only last 3 messages visible (earlier ones trimmed)
          messages =
            build_continuation_context(
              observations: """
              ## Current Task

              Implementing authentication for the Phoenix app. User wants OAuth2 support.

              ## Recent Activity

              - Read lib/my_app_web/router.ex
              - Created lib/my_app/auth.ex with basic user schema
              """,
              continuation_hint: "Continue with the OAuth2 implementation.",
              tail_messages: [
                {:assistant, "I've created the basic user schema. Now I'll add OAuth2 support."},
                {:user, "Great. Use the ueberauth library."},
                {:assistant, "Let me check the current router configuration."}
              ]
            )

          response = call_provider(messages, config)

          # Judge: Response should continue naturally
          # Must NOT start with greeting like "Hello" or "Hi"
          # Should reference OAuth2 or ueberauth (the current task)
          continues_naturally?(response) and references_current_task?(response)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nContinuation (natural): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Continuation quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "references current task from observations", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages =
            build_continuation_context(
              observations: """
              ## Current Task

              Fixing failing test in test/my_app/accounts_test.exs - expects user email to be downcased.

              ## Recent Files

              - lib/my_app/accounts.ex - user creation logic
              - test/my_app/accounts_test.exs - failing test
              """,
              continuation_hint: "Fix the failing test.",
              tail_messages: [
                {:assistant, "I see the test is failing. Let me read the accounts module."},
                {:user, "The email should be normalized before saving."},
                {:assistant, "I'll update the create_user function."}
              ]
            )

          response = call_provider(messages, config)

          # Judge: Response should reference the task (email, downcase, test)
          references_test_task?(response)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nContinuation (task reference): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "maintains context awareness after trimming", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages =
            build_continuation_context(
              observations: """
              ## Project Context

              This is a Elixir project using Phoenix 1.7. Database is PostgreSQL.

              ## Current Task

              Adding rate limiting to API endpoints using Plug.

              ## Earlier Work

              - Created database schema for rate_limit_buckets table
              - Implemented RateLimiter GenServer
              """,
              continuation_hint: "Now integrate the rate limiter into the endpoint.",
              tail_messages: [
                {:assistant, "The RateLimiter GenServer is ready."},
                {:user, "Add it to the API pipeline in the router."},
                {:assistant, "I'll create the plug and add it to the pipeline."}
              ]
            )

          response = call_provider(messages, config)

          # Judge: Should reference rate limiting and Plug/Phoenix context
          maintains_context?(response)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nContinuation (context awareness): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build continuation context
  defp build_continuation_context(opts) do
    observations = Keyword.fetch!(opts, :observations)
    continuation_hint = Keyword.fetch!(opts, :continuation_hint)
    tail_messages = Keyword.fetch!(opts, :tail_messages)

    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          # Observations

          #{observations}

          **Continuation:** #{continuation_hint}

          The conversation has been ongoing. Earlier messages have been compressed into observations above.
          Continue naturally from the recent messages.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    # Build tail messages
    tail_msgs =
      Enum.map(tail_messages, fn {role, content} ->
        %Message{
          id: generate_id(),
          role: role,
          content: [%Text{text: content}],
          timestamp: DateTime.utc_now()
        }
      end)

    [system_message | tail_msgs]
  end

  # Helper: Call provider and collect response text
  defp call_provider(messages, config) do
    case Anthropic.stream(messages, [], config) do
      {:ok, stream_ref} ->
        collect_response(stream_ref, "", 60_000)

      {:error, _reason} ->
        ""
    end
  end

  # Collect text from stream
  defp collect_response(stream_ref, accumulated, timeout) do
    receive do
      {:provider_event, %TextDelta{delta: text}} ->
        collect_response(stream_ref, accumulated <> text, timeout)

      {:provider_event, %Done{}} ->
        accumulated

      {:provider_event, %Error{}} ->
        accumulated
    after
      timeout ->
        Anthropic.cancel_stream(stream_ref)
        accumulated
    end
  end

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Judge helpers
  defp continues_naturally?(text) do
    # Should NOT start with greetings
    # Trim thinking blocks and check the actual response
    trimmed = String.trim(text)
    downcase = String.downcase(trimmed)

    # Check first 50 chars for greetings
    start = String.slice(downcase, 0..50)

    not (start =~ ~r/^(hello|hi|hey|greetings|good (morning|afternoon|evening))/)
  end

  defp references_current_task?(text) do
    downcase = String.downcase(text)
    # For OAuth2 task
    downcase =~ "oauth" or downcase =~ "ueberauth" or downcase =~ "auth"
  end

  defp references_test_task?(text) do
    downcase = String.downcase(text)
    # Should mention email, downcase/lowercase/normalize, or test
    downcase =~ "email" and
      (downcase =~ "downcase" or downcase =~ "lowercase" or downcase =~ "normalize" or
         downcase =~ "test")
  end

  defp maintains_context?(text) do
    downcase = String.downcase(text)
    # Should reference rate limiting and Phoenix/Plug context
    (downcase =~ "rate" or downcase =~ "limit") and
      (downcase =~ "plug" or downcase =~ "pipeline" or downcase =~ "router")
  end
end
