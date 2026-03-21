defmodule Deft.Eval.Actor.ObservationUsageTest do
  @moduledoc """
  Eval tests for Actor observation usage.

  Tests that the Actor (agent loop) correctly uses observations in its responses.
  Per spec section 4.1, the actor should reference observation content when relevant.

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.Provider.Anthropic
  alias Deft.Provider.Event.{TextDelta, Done, Error}

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  setup do
    config = Config.load()

    {:ok, config: config}
  end

  describe "observation usage - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "uses observations in response - argon2 preference", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Build context with observations + user prompt
          # Observation: User prefers argon2
          # Prompt: implement the login endpoint
          messages =
            build_context_with_observations(
              observations: """
              ## User Preferences

              - User prefers argon2 for password hashing (not bcrypt)
              """,
              prompt: "implement the login endpoint"
            )

          # Call provider and collect response
          response = call_provider(messages, config)

          # Judge: Does the response reference argon2?
          # Must NOT reference bcrypt (the alternative)
          references_argon2?(response) and not references_bcrypt?(response)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nObservation usage (argon2): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Observation usage below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "uses observations in response - code style preference", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages =
            build_context_with_observations(
              observations: """
              ## User Preferences

              - User prefers single quotes over double quotes for strings
              """,
              prompt: "write a function that returns a greeting message"
            )

          response = call_provider(messages, config)

          # Judge: Does the response reference or use single quotes?
          String.contains?(String.downcase(response), "single quote") or
            (String.contains?(response, "'") and
               count_occurrences(response, "'") >= count_occurrences(response, "\""))
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nObservation usage (code style): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "uses observations in response - architecture preference", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages =
            build_context_with_observations(
              observations: """
              ## Architectural Decisions

              - Use gen_statem for state machines, not GenServer (per team standard)
              """,
              prompt: "implement a connection manager with reconnect logic"
            )

          response = call_provider(messages, config)

          # Judge: Does the response reference gen_statem?
          # Must NOT suggest GenServer
          references_gen_statem?(response) and not references_genserver_for_state?(response)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nObservation usage (architecture): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build context with observations injected
  defp build_context_with_observations(opts) do
    observations = Keyword.fetch!(opts, :observations)
    prompt = Keyword.fetch!(opts, :prompt)

    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          # Observations

          #{observations}

          Use the observations above when responding to the user's request.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: prompt}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
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
  defp references_argon2?(text) do
    String.downcase(text) =~ "argon2"
  end

  defp references_bcrypt?(text) do
    String.downcase(text) =~ "bcrypt"
  end

  defp references_gen_statem?(text) do
    String.downcase(text) =~ "gen_statem"
  end

  defp references_genserver_for_state?(text) do
    downcase = String.downcase(text)
    # Check if GenServer is mentioned in context of state machine
    downcase =~ "genserver" and
      (downcase =~ "state" or downcase =~ "fsm" or downcase =~ "machine")
  end

  defp count_occurrences(text, substring) do
    text
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
