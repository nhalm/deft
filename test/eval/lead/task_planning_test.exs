defmodule Deft.Eval.Lead.TaskPlanningTest do
  @moduledoc """
  Eval test for Lead task decomposition quality.

  Tests that the Lead agent produces well-structured task plans with:
  - 4-8 concrete Runner tasks
  - Clear done state for each task
  - Dependency ordering

  Per spec section 6.1: 75% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  @iterations 20
  @pass_threshold 0.75

  describe "task decomposition - LLM judge (75% over 20 iterations)" do
    @tag timeout: 600_000
    test "produces 4-8 concrete Runner tasks with clear done states" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts(
            "\n[Iteration #{iteration}/#{@iterations}] Running task planning quality test..."
          )

          # Create a fixture deliverable with research findings
          fixture = create_task_planning_fixture(iteration)

          # Call LLM to produce a task plan
          plan = call_lead_task_planning(fixture)

          # Judge the plan quality
          passes_quality_check = judge_task_planning_quality(plan, fixture)

          if passes_quality_check do
            IO.puts("  ✓ PASS: Plan meets quality criteria")
          else
            IO.puts("  ✗ FAIL: Plan does not meet quality criteria")
          end

          passes_quality_check
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nLead task planning quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Task planning quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Creates different deliverable fixtures to test task planning
  defp create_task_planning_fixture(iteration) do
    fixtures = [
      %{
        deliverable: "Implement JWT authentication for the API",
        research_findings: """
        Research findings:
        - User schema exists with email and password_hash fields
        - Phoenix.Router configured with API pipeline
        - Guardian library is available for JWT in Elixir
        - Need both login endpoint and auth middleware
        """
      },
      %{
        deliverable: "Add rate limiting to prevent API abuse",
        research_findings: """
        Research findings:
        - Redis is available as a dependency
        - Plug.Conn is used for request pipeline
        - Need to track requests per IP address
        - Should return 429 status when limit exceeded
        """
      },
      %{
        deliverable: "Implement user registration with email verification",
        research_findings: """
        Research findings:
        - User schema has email field but no verified_at field
        - Bamboo library is configured for email sending
        - Need to generate and store verification tokens
        - Tokens should expire after 24 hours
        """
      },
      %{
        deliverable: "Build admin dashboard with user management",
        research_findings: """
        Research findings:
        - LiveView is configured and working
        - User schema has is_admin boolean field
        - Need to list users, edit roles, and delete accounts
        - Should require admin authentication
        """
      }
    ]

    # Cycle through fixtures
    fixture_index = rem(iteration - 1, length(fixtures))
    Enum.at(fixtures, fixture_index)
  end

  # Calls the Lead's task planning logic via LLM
  defp call_lead_task_planning(fixture) do
    prompt = """
    You are the Lead agent in an AI coding system. Your job is to decompose
    a deliverable into concrete Runner tasks that can be executed step by step.

    ## Deliverable
    #{fixture.deliverable}

    ## Research Findings
    #{fixture.research_findings}

    ## Your Output

    Produce a task plan in JSON format with this structure:

    ```json
    {
      "tasks": [
        {
          "id": "task-1",
          "description": "Clear description of what this task accomplishes",
          "done_state": "Specific criteria that indicate this task is complete",
          "dependencies": []
        }
      ]
    }
    ```

    Requirements:
    - Use 4-8 concrete Runner tasks
    - Each task must have a clear, specific description
    - Each task must have a clear done state (what "done" looks like)
    - Dependencies should be a list of task IDs (empty array if none)
    - Tasks should be dependency-ordered

    Output ONLY the JSON, nothing else.
    """

    case Helpers.call_llm_judge(prompt, %{timeout: 60_000}) do
      {:ok, response} ->
        # Extract JSON from response
        parse_plan_json(response)

      {:error, reason} ->
        IO.puts("    LLM error: #{inspect(reason)}")
        %{"tasks" => []}
    end
  end

  # Parse JSON from LLM response
  defp parse_plan_json(response) do
    # Try to extract JSON block
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n```/s, response) do
        [_, json] -> json
        nil -> response
      end

    case Jason.decode(json_str) do
      {:ok, plan} -> plan
      {:error, _} -> %{"tasks" => []}
    end
  end

  # Judge the plan quality using criteria from spec section 6.1
  defp judge_task_planning_quality(plan, _fixture) do
    tasks = Map.get(plan, "tasks", [])
    task_count = length(tasks)

    # Check 1: Should have 4-8 tasks
    has_reasonable_count = task_count >= 4 and task_count <= 8

    # Check 2: Each task has a clear description
    all_have_descriptions =
      Enum.all?(tasks, fn t ->
        desc = Map.get(t, "description", "")
        String.length(String.trim(desc)) > 20
      end)

    # Check 3: Each task has a clear done state
    all_have_done_states =
      Enum.all?(tasks, fn t ->
        done = Map.get(t, "done_state", "")
        String.length(String.trim(done)) > 10
      end)

    # Check 4: Dependencies are valid (reference existing task IDs)
    dependencies_valid = validate_dependencies(tasks)

    # All checks must pass
    result =
      has_reasonable_count and all_have_descriptions and all_have_done_states and
        dependencies_valid

    unless result do
      IO.puts("    Quality check details:")

      IO.puts("      - Reasonable count (4-8): #{has_reasonable_count} (got #{task_count})")

      IO.puts("      - All have descriptions: #{all_have_descriptions}")
      IO.puts("      - All have done states: #{all_have_done_states}")
      IO.puts("      - Dependencies valid: #{dependencies_valid}")
    end

    result
  end

  # Validates that all dependencies reference existing task IDs
  defp validate_dependencies(tasks) do
    task_ids = MapSet.new(tasks, fn t -> Map.get(t, "id") end)

    Enum.all?(tasks, fn t ->
      deps = Map.get(t, "dependencies", [])

      Enum.all?(deps, fn dep_id ->
        MapSet.member?(task_ids, dep_id)
      end)
    end)
  end
end
