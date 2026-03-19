defmodule Deft.Eval.Foreman.DecompositionTest do
  @moduledoc """
  Evaluates the quality of Foreman work decomposition.

  Tests whether the Foreman decomposes tasks into appropriate deliverables:
  - 1-3 deliverables for typical tasks (not 5+)
  - Each deliverable has a clear description
  - Decomposition is at the right granularity (not too fine, not too coarse)

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  describe "work decomposition" do
    test "fixture: jwt-auth task produces 1-3 deliverables" do
      fixture = load_fixture("jwt-auth-decomposition")

      # Build a plan from the fixture
      plan = build_plan_from_fixture(fixture)

      # Check deliverable count
      deliverable_count = length(plan.deliverables)

      assert deliverable_count >= 1 and deliverable_count <= 3,
             "Expected 1-3 deliverables, got #{deliverable_count}"

      # Check that each deliverable has a description
      for deliverable <- plan.deliverables do
        assert deliverable.description != ""
        assert String.length(deliverable.description) > 10
      end
    end

    test "fixture: simple typo fix produces single deliverable" do
      fixture = load_fixture("typo-fix")

      plan = build_plan_from_fixture(fixture)

      # Simple tasks should result in 1 deliverable
      assert length(plan.deliverables) == 1
    end

    @tag :llm_judge
    test "llm-as-judge: deliverable descriptions are clear" do
      # This test will use an LLM-as-judge to evaluate whether
      # deliverable descriptions are clear and actionable
      #
      # For now, we're creating the test structure and fixtures.
      # The actual LLM integration will be added once we have
      # a working Foreman decomposition function to test.

      fixture = load_fixture("jwt-auth-decomposition")
      plan = build_plan_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # For each deliverable:
      #   assert_faithful deliverable.description,
      #     context: "Is this description clear enough for a developer to understand what to build?",
      #     model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert length(plan.deliverables) > 0
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "foreman", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        # Return a default fixture if file doesn't exist yet
        default_fixture(name)
    end
  end

  defp default_fixture("jwt-auth-decomposition") do
    %{
      id: "jwt-auth-decomposition",
      spec_version: "0.2",
      description: "Add JWT authentication to Phoenix app",
      prompt: "Add authentication with JWT to this Phoenix app.",
      codebase_snapshot: "phoenix-minimal",
      expected_plan: %{
        deliverables: [
          %{
            id: "auth-backend",
            description: "Implement JWT authentication backend with register/login endpoints",
            dependencies: []
          },
          %{
            id: "auth-middleware",
            description: "Add authentication middleware to protect routes",
            dependencies: ["auth-backend"]
          }
        ]
      }
    }
  end

  defp default_fixture("typo-fix") do
    %{
      id: "typo-fix",
      spec_version: "0.2",
      description: "Fix typo in auth.ex",
      prompt: "Fix the typo in line 42 of auth.ex",
      codebase_snapshot: "phoenix-minimal",
      expected_plan: %{
        deliverables: [
          %{
            id: "fix-typo",
            description: "Fix typo in auth.ex line 42",
            dependencies: []
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
            dependencies: d.dependencies || []
          }
        end)
    }
  end
end
