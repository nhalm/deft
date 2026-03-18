defmodule Deft.Eval.Actor.ContinuationTest do
  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.EvalHelpers
  alias Deft.OM.State, as: OMState
  alias Deft.Provider.Event.{TextDelta, Done}

  @moduletag :eval
  @moduletag :expensive
  @moduletag timeout: 600_000

  # Number of iterations for statistical test
  @iterations 20

  # Pass rate threshold (90% as per spec)
  @pass_rate_threshold 0.90

  setup_all do
    # Ensure Registry is running
    case Process.whereis(Deft.Registry) do
      nil -> Registry.start_link(keys: :duplicate, name: Deft.Registry)
      _pid -> :ok
    end

    # Ensure ProcessRegistry is running
    case Process.whereis(Deft.ProcessRegistry) do
      nil -> Registry.start_link(keys: :unique, name: Deft.ProcessRegistry)
      _pid -> :ok
    end

    :ok
  end

  describe "continuation after trimming" do
    @tag timeout: 600_000
    test "actor continues naturally without greeting (20 iterations, 90% pass rate)" do
      results =
        for i <- 1..@iterations do
          result = run_continuation_test(i)

          IO.puts(
            "  Iteration #{i}: #{if result.passed, do: "PASS", else: "FAIL"} - #{result.reason}"
          )

          result
        end

      # Calculate pass rate
      passes = Enum.count(results, & &1.passed)
      pass_rate = passes / @iterations

      # Log results
      IO.puts("\n=== Continuation Test Results ===")
      IO.puts("Passes: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("Threshold: #{Float.round(@pass_rate_threshold * 100, 1)}%")

      # Show failures
      failures = Enum.filter(results, &(not &1.passed))

      if not Enum.empty?(failures) do
        IO.puts("\nFailures:")

        Enum.each(failures, fn result ->
          IO.puts("  - #{result.reason}")
        end)
      end

      assert pass_rate >= @pass_rate_threshold,
             "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{Float.round(@pass_rate_threshold * 100, 1)}%"
    end
  end

  # Runs a single continuation test iteration
  defp run_continuation_test(iteration_num) do
    session_id = "eval_continuation_#{iteration_num}_#{:rand.uniform(10000)}"

    config =
      EvalHelpers.test_config()
      |> Map.put(:om_enabled, true)
      |> Map.put(:provider, Deft.Provider.Anthropic)

    # Start the OM.State process
    {:ok, _om_pid} =
      OMState.start_link(
        session_id: session_id,
        config: config,
        name: {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}}
      )

    # Create a conversation context that simulates being mid-task after message trimming
    # The continuation hint will indicate we're in the middle of implementing a feature
    continuation_hint =
      "You are implementing authentication for a web application. The user has asked you to add password hashing to the login endpoint."

    # Create a trimmed conversation with just the last few messages
    # Simulating that earlier messages have been observed and trimmed
    initial_messages = [
      EvalHelpers.user_message("Add password hashing to the login function."),
      EvalHelpers.assistant_message(
        "I'll add password hashing using argon2. Let me update the login function."
      ),
      EvalHelpers.user_message("Make sure to handle errors properly.")
    ]

    # Add messages to OM.State
    Enum.each(initial_messages, fn msg ->
      OMState.add_message(session_id, msg)
    end)

    # Set the continuation hint
    # Note: This is a simplification - in production, the continuation hint comes from the Reflector
    # For this eval, we'll manually set the state to include a continuation hint
    :sys.replace_state(
      {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}},
      fn state ->
        %{state | continuation_hint: continuation_hint}
      end
    )

    # Start the agent with the trimmed conversation
    {:ok, agent} =
      Agent.start_link(
        session_id: session_id,
        config: config,
        messages: initial_messages
      )

    # Subscribe to agent events to capture response
    Registry.register(Deft.Registry, {:agent, session_id}, [])

    # Send a continuation prompt
    Agent.prompt(agent, "What's the next step?")

    # Collect the agent's response
    response_text = collect_agent_response(session_id, 45_000)

    # Stop processes
    if Process.alive?(agent), do: :gen_statem.stop(agent)

    case Registry.lookup(Deft.ProcessRegistry, {:om_state, session_id}) do
      [{om_pid, _}] -> if Process.alive?(om_pid), do: GenServer.stop(om_pid)
      [] -> :ok
    end

    # Verify the response:
    # 1. Does NOT contain greeting patterns (Hello, Hi, Hey, Good morning, etc.)
    # 2. References the current task (authentication, password hashing, login)
    has_greeting? =
      String.match?(response_text, ~r/(^|\n)(Hello|Hi|Hey|Good (morning|afternoon|evening))/i)

    references_task? = String.match?(response_text, ~r/(auth|password|hash|login)/i)

    cond do
      has_greeting? ->
        %{
          passed: false,
          reason:
            "Response contains greeting when it should continue naturally. Response: #{String.slice(response_text, 0..200)}"
        }

      not references_task? ->
        %{
          passed: false,
          reason:
            "Response does not reference the current task. Response: #{String.slice(response_text, 0..200)}"
        }

      true ->
        %{passed: true, reason: "Response continues naturally and references current task"}
    end
  end

  # Collects agent response text from Registry events
  defp collect_agent_response(session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_agent_response_loop(session_id, deadline, "")
  end

  defp collect_agent_response_loop(session_id, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {:agent_event, ^session_id, %TextDelta{delta: text}} ->
          collect_agent_response_loop(session_id, deadline, acc <> text)

        {:agent_event, ^session_id, %Done{}} ->
          acc

        {:agent_event, ^session_id, _other} ->
          collect_agent_response_loop(session_id, deadline, acc)
      after
        remaining ->
          acc
      end
    end
  end
end
