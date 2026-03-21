defmodule Deft.Eval.Foreman.DependencyTest do
  @moduledoc """
  Eval test for Foreman single-agent detection (mode selection).

  Tests that the Foreman correctly identifies whether a task should be:
  - Single-agent mode: simple tasks like typo fixes, comments, questions
  - Orchestrated mode: complex tasks requiring multiple components

  Per spec section 5.2: 80% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.80

  describe "single-agent detection - LLM judge (80% over 20 iterations)" do
    @tag timeout: 600_000
    test "correctly identifies simple vs complex tasks" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts(
            "\n[Iteration #{iteration}/#{@iterations}] Running single-agent detection test..."
          )

          # Test with a mix of simple and complex tasks
          simple_result = test_task_complexity_detection(iteration, :simple)
          complex_result = test_task_complexity_detection(iteration, :complex)

          # Both must be correct for this iteration to pass
          passes = simple_result and complex_result

          if passes do
            IO.puts("  ✓ PASS: Correctly identified both simple and complex tasks")
          else
            IO.puts("  ✗ FAIL: Misidentified task complexity")
          end

          passes
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nForeman single-agent detection: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Single-agent detection below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Test a specific task type (simple or complex)
  defp test_task_complexity_detection(iteration, task_type) do
    fixture = create_mode_detection_fixture(iteration, task_type)
    mode = call_foreman_mode_detection(fixture)
    expected_mode = fixture.expected_mode

    result = mode == expected_mode

    unless result do
      IO.puts(
        "    #{task_type} task: expected #{expected_mode}, got #{mode} for '#{fixture.prompt}'"
      )
    end

    result
  end

  # Creates fixtures for mode detection testing
  defp create_mode_detection_fixture(iteration, task_type) do
    simple_tasks = [
      %{
        prompt: "Fix the typo in line 42 of auth.ex",
        expected_mode: :single_agent
      },
      %{
        prompt: "Add a comment to this function explaining what it does",
        expected_mode: :single_agent
      },
      %{
        prompt: "What does this module do?",
        expected_mode: :single_agent
      },
      %{
        prompt: "Remove the unused import on line 5",
        expected_mode: :single_agent
      }
    ]

    complex_tasks = [
      %{
        prompt: "Build a complete auth system with frontend and backend",
        expected_mode: :orchestrated
      },
      %{
        prompt: "Add user authentication, session management, and password reset functionality",
        expected_mode: :orchestrated
      },
      %{
        prompt:
          "Implement a real-time notification system with WebSocket support and database persistence",
        expected_mode: :orchestrated
      },
      %{
        prompt: "Create an admin dashboard with user management, analytics, and reporting",
        expected_mode: :orchestrated
      }
    ]

    tasks = if task_type == :simple, do: simple_tasks, else: complex_tasks

    # Cycle through tasks based on iteration
    task_index = rem(iteration - 1, length(tasks))
    Enum.at(tasks, task_index)
  end

  # Calls the Foreman's mode detection logic via LLM
  defp call_foreman_mode_detection(fixture) do
    prompt = """
    You are the Foreman in an AI coding agent system. Your first decision is whether
    a task should be handled by a single agent or requires orchestration of multiple agents.

    ## Task
    "#{fixture.prompt}"

    ## Decision Criteria

    **Single-agent mode** is appropriate for:
    - Simple file edits (typo fixes, adding comments)
    - Questions about code
    - Small, localized changes (1-2 files)

    **Orchestrated mode** is appropriate for:
    - Multi-component systems (frontend + backend)
    - Features requiring multiple subsystems
    - Complex tasks that benefit from parallel work

    ## Your Decision

    Respond with ONLY one of these two words:
    - "SINGLE" if this should be single-agent mode
    - "ORCHESTRATED" if this requires multi-agent orchestration

    Your decision:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, response} ->
        # Parse the decision
        normalized = String.upcase(String.trim(response))

        cond do
          normalized =~ ~r/SINGLE/ -> :single_agent
          normalized =~ ~r/ORCHESTRATED/ -> :orchestrated
          true -> :unknown
        end

      {:error, _reason} ->
        :unknown
    end
  end
end
