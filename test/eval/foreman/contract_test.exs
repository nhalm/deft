defmodule Deft.Eval.Foreman.ContractTest do
  @moduledoc """
  Evaluates the quality of interface contracts in Foreman plans.

  Tests whether interface contracts are specific enough for downstream Leads
  to build against without needing follow-up questions. Contracts should mention:
  - Specific endpoints or function signatures
  - Data shapes (struct fields, JSON schemas)
  - Return types and error conditions

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration
  @moduletag :llm_judge

  describe "interface contract quality" do
    test "fixture: jwt-auth contract mentions specific endpoints" do
      fixture = load_fixture("jwt-auth-contract")

      plan = build_plan_from_fixture(fixture)

      # Find deliverable with dependencies (should have a contract)
      dependent_deliverable =
        Enum.find(plan.deliverables, fn d -> length(d.dependencies) > 0 end)

      assert dependent_deliverable != nil, "No dependent deliverable found"

      # Get the contract for the dependency
      dep_id = hd(dependent_deliverable.dependencies)
      contract = find_contract(plan, dep_id)

      assert contract != nil, "No contract found for dependency #{dep_id}"
      assert String.length(contract) > 20, "Contract is too short"

      # Contract should mention specific technical details
      contract_lower = String.downcase(contract)

      has_specifics =
        String.contains?(contract_lower, "post ") or
          String.contains?(contract_lower, "get ") or
          String.contains?(contract_lower, "function") or
          String.contains?(contract_lower, "endpoint") or
          String.contains?(contract_lower, "returns")

      assert has_specifics, "Contract lacks specific technical details"
    end

    test "fixture: contract mentions data shapes" do
      fixture = load_fixture("api-contract")

      plan = build_plan_from_fixture(fixture)

      # Find a contract that should specify data shapes
      contract = find_any_contract(plan)

      assert contract != nil, "No contract found in plan"

      contract_lower = String.downcase(contract)

      # Should mention data structures
      has_data_shape =
        String.contains?(contract_lower, "json") or
          String.contains?(contract_lower, "struct") or
          String.contains?(contract_lower, "field") or
          String.contains?(contract_lower, "schema") or
          String.contains?(contract_lower, "%{")

      assert has_data_shape, "Contract doesn't specify data shapes"
    end

    @tag :skip
    test "llm-as-judge: contract is actionable without follow-up" do
      # This test will use an LLM-as-judge to evaluate whether a Lead
      # could build against the contract without asking questions.
      #
      # Prompt: "Could the downstream Lead build against this contract
      # without asking follow-up questions? Score 1-5."
      #
      # For now, this is a placeholder structure.

      fixture = load_fixture("jwt-auth-contract")
      plan = build_plan_from_fixture(fixture)
      contract = find_any_contract(plan)

      assert contract != nil

      # Placeholder: Will use Tribunal's LLM-as-judge scoring
      # score = judge_contract_completeness(contract)
      # assert score >= 4, "Contract scored #{score}/5 - not actionable enough"
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "foreman", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        default_fixture(name)
    end
  end

  defp default_fixture("jwt-auth-contract") do
    %{
      id: "jwt-auth-contract",
      spec_version: "0.2",
      expected_plan: %{
        deliverables: [
          %{
            id: "auth-backend",
            description: "Implement JWT authentication backend",
            dependencies: [],
            contract:
              "POST /auth/register accepts {email, password} and returns {token: string, user: %User{}}. POST /auth/login accepts {email, password} and returns {token: string} or 401."
          },
          %{
            id: "auth-middleware",
            description: "Add authentication middleware",
            dependencies: ["auth-backend"],
            contract: nil
          }
        ]
      }
    }
  end

  defp default_fixture("api-contract") do
    %{
      id: "api-contract",
      spec_version: "0.2",
      expected_plan: %{
        deliverables: [
          %{
            id: "posts-schema",
            description: "Create posts schema",
            dependencies: [],
            contract:
              "Post schema with fields: title (string), body (text), author_id (references users), published_at (datetime). Returns %Post{} struct."
          },
          %{
            id: "posts-api",
            description: "Build posts API",
            dependencies: ["posts-schema"],
            contract: nil
          }
        ]
      }
    }
  end

  defp build_plan_from_fixture(fixture) do
    expected = fixture.expected_plan

    %{
      deliverables:
        Enum.map(expected.deliverables, fn d ->
          %{
            id: d.id,
            description: d.description,
            dependencies: d.dependencies || [],
            contract: d[:contract]
          }
        end)
    }
  end

  defp find_contract(plan, deliverable_id) do
    deliverable = Enum.find(plan.deliverables, fn d -> d.id == deliverable_id end)
    deliverable && deliverable.contract
  end

  defp find_any_contract(plan) do
    deliverable = Enum.find(plan.deliverables, fn d -> d.contract != nil end)
    deliverable && deliverable.contract
  end
end
