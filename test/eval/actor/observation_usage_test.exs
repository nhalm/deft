defmodule Deft.Eval.Actor.ObservationUsageTest do
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

  # Pass rate threshold (85% as per spec)
  @pass_rate_threshold 0.85

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

  describe "observation usage" do
    @tag timeout: 600_000
    test "actor references observations in response (20 iterations, 85% pass rate)" do
      results =
        for i <- 1..@iterations do
          result = run_observation_usage_test(i)

          IO.puts(
            "  Iteration #{i}: #{if result.passed, do: "PASS", else: "FAIL"} - #{result.reason}"
          )

          result
        end

      # Calculate pass rate
      passes = Enum.count(results, & &1.passed)
      pass_rate = passes / @iterations

      # Log results
      IO.puts("\n=== Observation Usage Test Results ===")
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

  # Runs a single observation usage test iteration
  defp run_observation_usage_test(iteration_num) do
    session_id = "eval_obs_usage_#{iteration_num}_#{:rand.uniform(10000)}"

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

    # Populate observations by sending messages and triggering observe
    initial_messages = [
      EvalHelpers.user_message("We use PostgreSQL and prefer argon2 for password hashing."),
      EvalHelpers.assistant_message(
        "I'll keep that in mind. Your stack uses PostgreSQL and argon2 for password hashing."
      )
    ]

    # Add messages to OM.State
    Enum.each(initial_messages, fn msg ->
      OMState.add_message(session_id, msg)
    end)

    # Force an observation cycle to populate active_observations
    {:ok, _} = OMState.force_observe(session_id, 60_000)

    # Small delay to ensure observation is complete
    Process.sleep(500)

    # Start the agent
    {:ok, agent} =
      Agent.start_link(
        session_id: session_id,
        config: config,
        messages: []
      )

    # Subscribe to agent events to capture response
    Registry.register(Deft.Registry, {:agent, session_id}, [])

    # Send prompt asking to implement login endpoint
    Agent.prompt(agent, "implement the login endpoint")

    # Collect the agent's response
    response_text = collect_agent_response(session_id, 45_000)

    # Stop processes
    if Process.alive?(agent), do: :gen_statem.stop(agent)

    case Registry.lookup(Deft.ProcessRegistry, {:om_state, session_id}) do
      [{om_pid, _}] -> if Process.alive?(om_pid), do: GenServer.stop(om_pid)
      [] -> :ok
    end

    # Verify the response mentions argon2 (case-insensitive)
    mentions_argon2? = String.match?(response_text, ~r/argon2/i)

    if mentions_argon2? do
      %{passed: true, reason: "Response correctly references argon2 from observations"}
    else
      %{
        passed: false,
        reason:
          "Response does not mention argon2. Response: #{String.slice(response_text, 0..200)}"
      }
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
