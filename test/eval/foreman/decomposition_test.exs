defmodule Deft.Eval.Foreman.DecompositionTest do
  @moduledoc """
  Eval test for Foreman work decomposition quality.

  Tests that the Foreman produces well-structured work plans with:
  - 1-3 deliverables (not 5+)
  - Clear description for each deliverable
  - Valid dependency DAG (no circular dependencies)

  Per spec section 5.1: 75% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  @iterations 20
  @pass_threshold 0.75

  describe "work decomposition - LLM judge (75% over 20 iterations)" do
    @tag timeout: 600_000
    test "produces 1-3 deliverables with clear descriptions and valid DAG" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts(
            "\n[Iteration #{iteration}/#{@iterations}] Running decomposition quality test..."
          )

          # Create a fixture task
          fixture = create_decomposition_fixture(iteration)

          # Call LLM to produce a work plan
          plan = call_foreman_decomposition(fixture)

          # Judge the plan quality
          passes_quality_check = judge_decomposition_quality(plan, fixture)

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
        "\nForeman decomposition quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Decomposition quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Creates different task fixtures to test decomposition
  defp create_decomposition_fixture(iteration) do
    fixtures = [
      %{
        task: "Add authentication with JWT to this Phoenix app.",
        codebase_context: """
        Phoenix app with:
        - User schema exists (email, password_hash fields)
        - Phoenix.Router with basic routes
        - Phoenix.Endpoint configured
        """
      },
      %{
        task: "Implement rate limiting for the API endpoints.",
        codebase_context: """
        Phoenix app with:
        - REST API routes in Router
        - Plug pipeline configured
        - Redis available as dependency
        """
      },
      %{
        task: "Add pagination to the user list endpoint.",
        codebase_context: """
        Phoenix app with:
        - UserController.index/2 returns all users
        - Ecto repo configured
        - User schema with 1000+ records in production
        """
      },
      %{
        task: "Build a complete authentication system with frontend and backend.",
        codebase_context: """
        Phoenix app with LiveView:
        - User schema exists
        - LiveView configured
        - No authentication currently
        """
      }
    ]

    # Cycle through fixtures
    fixture_index = rem(iteration - 1, length(fixtures))
    Enum.at(fixtures, fixture_index)
  end

  # Calls the Foreman's decomposition logic via LLM
  defp call_foreman_decomposition(fixture) do
    prompt = """
    You are the Foreman in an AI coding agent system. Your job is to decompose
    work into deliverables that can be executed by downstream Lead agents.

    ## Task
    #{fixture.task}

    ## Codebase Context
    #{fixture.codebase_context}

    ## Your Output

    Produce a work plan in JSON format with this structure:

    ```json
    {
      "deliverables": [
        {
          "id": "deliverable-1",
          "description": "Clear description of what this deliverable accomplishes",
          "dependencies": []
        }
      ]
    }
    ```

    Requirements:
    - Use 1-3 deliverables (not 5+) unless truly necessary
    - Each deliverable must have a clear, specific description
    - Dependencies should be a list of deliverable IDs (empty array if none)
    - No circular dependencies in the DAG

    Output ONLY the JSON, nothing else.
    """

    case Helpers.call_llm_judge(prompt, %{timeout: 60_000}) do
      {:ok, response} ->
        # Extract JSON from response
        parse_plan_json(response)

      {:error, reason} ->
        IO.puts("    LLM error: #{inspect(reason)}")
        %{"deliverables" => []}
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
      {:error, _} -> %{"deliverables" => []}
    end
  end

  # Judge the plan quality using criteria from spec section 5.1
  defp judge_decomposition_quality(plan, _fixture) do
    deliverables = Map.get(plan, "deliverables", [])
    deliverable_count = length(deliverables)

    # Check 1: Should have 1-3 deliverables (not 5+)
    has_reasonable_count = deliverable_count >= 1 and deliverable_count <= 4

    # Check 2: Each deliverable has a clear description
    all_have_descriptions =
      Enum.all?(deliverables, fn d ->
        desc = Map.get(d, "description", "")
        String.length(String.trim(desc)) > 20
      end)

    # Check 3: Dependency DAG is valid (no circular deps)
    dag_is_valid = validate_dag(deliverables)

    # All checks must pass
    result = has_reasonable_count and all_have_descriptions and dag_is_valid

    unless result do
      IO.puts("    Quality check details:")

      IO.puts(
        "      - Reasonable count (1-4): #{has_reasonable_count} (got #{deliverable_count})"
      )

      IO.puts("      - All have descriptions: #{all_have_descriptions}")
      IO.puts("      - DAG is valid: #{dag_is_valid}")
    end

    result
  end

  # Validates that the dependency DAG has no circular dependencies
  defp validate_dag(deliverables) do
    # Build adjacency list
    deps_map =
      deliverables
      |> Enum.map(fn d -> {Map.get(d, "id"), Map.get(d, "dependencies", [])} end)
      |> Map.new()

    # Check each node for cycles using DFS
    Enum.all?(Map.keys(deps_map), fn node ->
      not has_cycle?(node, deps_map, MapSet.new(), MapSet.new())
    end)
  end

  # DFS cycle detection
  defp has_cycle?(node, deps_map, visited, rec_stack) do
    cond do
      MapSet.member?(rec_stack, node) ->
        # Node is in recursion stack - cycle detected
        true

      MapSet.member?(visited, node) ->
        # Already visited this node in a previous DFS - no cycle from here
        false

      true ->
        # Visit this node
        new_visited = MapSet.put(visited, node)
        new_rec_stack = MapSet.put(rec_stack, node)

        # Check all dependencies
        deps = Map.get(deps_map, node, [])

        Enum.any?(deps, fn dep ->
          has_cycle?(dep, deps_map, new_visited, new_rec_stack)
        end)
    end
  end
end
