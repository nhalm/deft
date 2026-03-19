defmodule Deft.Eval.Actor.ToolSelectionTest do
  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.EvalHelpers
  alias Deft.Provider.Event.{ToolCallStart, Done}

  @moduletag :eval
  @moduletag :expensive
  @moduletag timeout: 600_000

  # Number of iterations per test case
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

  describe "tool selection" do
    @tag timeout: 600_000
    test "selects correct tools for various prompts (20 iterations, 85% pass rate)" do
      # Test cases from spec
      test_cases = [
        %{
          prompt: "Read src/auth.ex",
          expected_tool: "read",
          forbidden_tools: ["bash"]
        },
        %{
          prompt: "Find all test files",
          expected_tool: "find",
          forbidden_tools: ["bash"]
        },
        %{
          prompt: "Search for 'defmodule Auth'",
          expected_tool: "grep",
          forbidden_tools: ["bash"]
        },
        %{
          prompt: "Run the tests",
          expected_tool: "bash",
          forbidden_tools: []
        },
        %{
          prompt: "Change foo to bar in config.exs",
          expected_tool: "edit",
          forbidden_tools: ["bash"]
        }
      ]

      # Run each test case multiple times
      all_results =
        for test_case <- test_cases do
          IO.puts("\n--- Testing: #{test_case.prompt} ---")
          IO.puts("Expected tool: #{test_case.expected_tool}")

          results =
            for i <- 1..@iterations do
              result = run_tool_selection_test(test_case, i)

              IO.puts(
                "  Iteration #{i}: #{if result.passed, do: "PASS", else: "FAIL"} - #{result.reason}"
              )

              result
            end

          passes = Enum.count(results, & &1.passed)
          pass_rate = passes / @iterations

          IO.puts("Pass rate: #{Float.round(pass_rate * 100, 1)}%")

          %{test_case: test_case, results: results, pass_rate: pass_rate}
        end

      # Calculate overall pass rate
      total_tests = length(test_cases) * @iterations

      total_passes =
        Enum.sum(Enum.map(all_results, fn r -> Enum.count(r.results, & &1.passed) end))

      overall_pass_rate = total_passes / total_tests

      # Log overall results
      IO.puts("\n=== Tool Selection Test Results ===")

      IO.puts(
        "Overall: #{total_passes}/#{total_tests} (#{Float.round(overall_pass_rate * 100, 1)}%)"
      )

      IO.puts("Threshold: #{Float.round(@pass_rate_threshold * 100, 1)}%")

      # Show per-case summary
      IO.puts("\nPer-Case Summary:")

      Enum.each(all_results, fn %{test_case: tc, pass_rate: pr} ->
        status = if pr >= @pass_rate_threshold, do: "✓", else: "✗"
        IO.puts("  #{status} #{tc.prompt}: #{Float.round(pr * 100, 1)}%")
      end)

      assert overall_pass_rate >= @pass_rate_threshold,
             "Overall pass rate #{Float.round(overall_pass_rate * 100, 1)}% below threshold #{Float.round(@pass_rate_threshold * 100, 1)}%"
    end
  end

  # Runs a single tool selection test iteration
  defp run_tool_selection_test(test_case, iteration_num) do
    session_id = "eval_tool_sel_#{iteration_num}_#{:rand.uniform(10000)}"

    config =
      EvalHelpers.test_config()
      |> Map.put(:om_enabled, false)
      |> Map.put(:provider, Deft.Provider.Anthropic)

    # Start the agent
    {:ok, agent} =
      Agent.start_link(
        session_id: session_id,
        config: config,
        messages: []
      )

    # Subscribe to agent events to capture tool calls
    Registry.register(Deft.Registry, {:agent, session_id}, [])

    # Send the prompt
    Agent.prompt(agent, test_case.prompt)

    # Collect tool calls from the agent
    tool_calls = collect_tool_calls(session_id, 45_000)

    # Stop the agent
    if Process.alive?(agent), do: :gen_statem.stop(agent)

    # Verify tool selection
    validate_tool_selection(test_case, tool_calls)
  end

  # Collects tool calls from agent events
  defp collect_tool_calls(session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_tool_calls_loop(session_id, deadline, [])
  end

  defp collect_tool_calls_loop(session_id, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {:agent_event, ^session_id, %ToolCallStart{name: name}} ->
          collect_tool_calls_loop(session_id, deadline, [name | acc])

        {:agent_event, ^session_id, %Done{}} ->
          Enum.reverse(acc)

        {:agent_event, ^session_id, _other} ->
          collect_tool_calls_loop(session_id, deadline, acc)
      after
        remaining ->
          Enum.reverse(acc)
      end
    end
  end

  # Validates that the tool calls match expectations
  defp validate_tool_selection(test_case, tool_calls) do
    %{
      expected_tool: expected_tool,
      forbidden_tools: forbidden_tools
    } = test_case

    cond do
      Enum.empty?(tool_calls) ->
        %{
          passed: false,
          reason: "No tool calls made (expected #{expected_tool})"
        }

      not Enum.member?(tool_calls, expected_tool) ->
        %{
          passed: false,
          reason: "Expected tool '#{expected_tool}' not called. Called: #{inspect(tool_calls)}"
        }

      Enum.any?(forbidden_tools, &Enum.member?(tool_calls, &1)) ->
        forbidden_used = Enum.filter(forbidden_tools, &Enum.member?(tool_calls, &1))

        %{
          passed: false,
          reason:
            "Used forbidden tool(s): #{inspect(forbidden_used)}. All calls: #{inspect(tool_calls)}"
        }

      true ->
        %{
          passed: true,
          reason: "Correctly called #{expected_tool}"
        }
    end
  end
end
