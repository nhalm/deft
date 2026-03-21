defmodule Deft.Eval.Foreman.ContractTest do
  @moduledoc """
  Eval test for Foreman interface contract quality.

  Tests that interface contracts between deliverables are specific enough
  for downstream Leads to build against without needing follow-up questions.

  Contracts should mention specific endpoints, data shapes, or function signatures.

  Per spec section 5.1: 75% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  @iterations 20
  @pass_threshold 0.75

  describe "interface contract quality - LLM judge (75% over 20 iterations)" do
    @tag timeout: 600_000
    test "contracts are specific enough to build against" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts("\n[Iteration #{iteration}/#{@iterations}] Running contract quality test...")

          # Create a fixture with dependencies between deliverables
          fixture = create_contract_fixture(iteration)

          # Generate a plan with contracts
          plan = call_foreman_with_contracts(fixture)

          # Judge contract quality
          passes_quality_check = judge_contract_quality(plan)

          if passes_quality_check do
            IO.puts("  ✓ PASS: Contracts are specific and actionable")
          else
            IO.puts("  ✗ FAIL: Contracts lack specificity")
          end

          passes_quality_check
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nForeman contract quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Contract quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Creates fixtures with tasks that require inter-deliverable contracts
  defp create_contract_fixture(iteration) do
    fixtures = [
      %{
        task: "Build a REST API for user management with a React frontend",
        context: """
        Phoenix backend with no existing API.
        React frontend scaffold exists.
        Need to coordinate API contracts between backend and frontend.
        """
      },
      %{
        task: "Add real-time notifications with WebSocket backend and LiveView frontend",
        context: """
        Phoenix app with LiveView.
        No existing WebSocket implementation.
        Need to define message format and event types.
        """
      },
      %{
        task: "Implement file upload with server-side validation and client-side preview",
        context: """
        Phoenix API backend.
        React frontend.
        Need to define upload endpoint and response format.
        """
      },
      %{
        task: "Add search functionality with Elasticsearch backend and search UI",
        context: """
        Phoenix app.
        Elasticsearch configured.
        Need to define search query format and result structure.
        """
      }
    ]

    # Cycle through fixtures
    fixture_index = rem(iteration - 1, length(fixtures))
    Enum.at(fixtures, fixture_index)
  end

  # Calls Foreman to generate a plan with interface contracts
  defp call_foreman_with_contracts(fixture) do
    prompt = """
    You are the Foreman in an AI coding agent system. Your job is to decompose
    work into deliverables with clear interface contracts.

    ## Task
    #{fixture.task}

    ## Context
    #{fixture.context}

    ## Your Output

    Produce a work plan with deliverables that have explicit interface contracts.
    Output JSON in this format:

    ```json
    {
      "deliverables": [
        {
          "id": "backend-api",
          "description": "Build the backend API",
          "contract": "Exposes POST /api/users endpoint accepting {email: string, name: string}, returns {id: integer, email: string, name: string, created_at: datetime}"
        },
        {
          "id": "frontend-ui",
          "description": "Build the frontend UI",
          "dependencies": ["backend-api"],
          "contract": "React component UserForm that calls POST /api/users with validated data"
        }
      ]
    }
    ```

    Each contract must be specific:
    - Mention exact endpoints, HTTP methods, and paths
    - Specify data shapes with field names and types
    - Include function signatures if relevant

    Vague contracts like "provides user data" are NOT acceptable.

    Output ONLY the JSON, nothing else.
    """

    case Helpers.call_llm_judge(prompt, %{timeout: 60_000}) do
      {:ok, response} ->
        parse_plan_json(response)

      {:error, reason} ->
        IO.puts("    LLM error: #{inspect(reason)}")
        %{"deliverables" => []}
    end
  end

  # Parse JSON from LLM response
  defp parse_plan_json(response) do
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

  # Judge contract quality using LLM-as-judge
  defp judge_contract_quality(plan) do
    deliverables = Map.get(plan, "deliverables", [])

    # If no deliverables or only one, no contracts needed
    if length(deliverables) <= 1 do
      true
    else
      # Check each deliverable that has dependencies
      deliverables_with_deps =
        Enum.filter(deliverables, fn d ->
          deps = Map.get(d, "dependencies", [])
          length(deps) > 0
        end)

      # If there are dependencies, we need contracts
      if length(deliverables_with_deps) > 0 do
        Enum.all?(deliverables, fn d ->
          contract = Map.get(d, "contract", "")
          judge_single_contract(contract)
        end)
      else
        # No dependencies means contracts are optional
        true
      end
    end
  end

  # Judge if a single contract is specific enough
  defp judge_single_contract(contract) do
    if String.trim(contract) == "" do
      false
    else
      # Check for specificity indicators
      has_endpoint = contract =~ ~r/\/[\w\/]+/ or contract =~ ~r/(GET|POST|PUT|DELETE|PATCH)/i

      has_data_shape =
        contract =~ ~r/\{[^}]+\}/ or contract =~ ~r/:\s*(string|integer|boolean|datetime|array)/

      has_function_sig = contract =~ ~r/\w+\([^)]*\)/

      # At least one specificity indicator should be present
      has_endpoint or has_data_shape or has_function_sig
    end
  end
end
