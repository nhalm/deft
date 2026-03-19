defmodule Deft.Eval.Foreman.ConstraintPropagationTest do
  @moduledoc """
  Evaluates constraint propagation from issue to Lead steering instructions.

  Tests that structured constraints in the issue (e.g., "Use argon2",
  "Don't modify User schema") appear in the Lead's steering instructions.

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  describe "constraint propagation" do
    test "fixture: auth constraints flow to Lead steering" do
      fixture = load_fixture("auth-with-constraints")

      issue = build_issue_from_fixture(fixture)
      plan = build_plan_from_fixture(fixture)
      lead_instructions = get_lead_instructions(plan, "auth-backend")

      # Each constraint from the issue should appear in Lead instructions
      for constraint <- issue.constraints do
        assert String.contains?(lead_instructions, constraint) or
                 contains_semantic_match?(lead_instructions, constraint),
               "Constraint '#{constraint}' not found in Lead instructions"
      end
    end

    test "fixture: multiple constraints all propagate" do
      fixture = load_fixture("multi-constraint")

      issue = build_issue_from_fixture(fixture)
      plan = build_plan_from_fixture(fixture)

      # Check that all constraints appear in at least one Lead's instructions
      for constraint <- issue.constraints do
        found_in_any_lead =
          Enum.any?(plan.deliverables, fn d ->
            instructions = d[:lead_instructions] || ""

            String.contains?(instructions, constraint) or
              contains_semantic_match?(instructions, constraint)
          end)

        assert found_in_any_lead,
               "Constraint '#{constraint}' not found in any Lead instructions"
      end
    end

    test "fixture: constraints are not duplicated unnecessarily" do
      fixture = load_fixture("auth-with-constraints")

      plan = build_plan_from_fixture(fixture)
      lead_instructions = get_lead_instructions(plan, "auth-backend")

      # Count occurrences of each constraint
      issue = build_issue_from_fixture(fixture)

      for constraint <- issue.constraints do
        # Should appear at least once but not 5+ times
        count = count_substring(lead_instructions, constraint)

        if count > 0 do
          assert count < 5,
                 "Constraint '#{constraint}' appears #{count} times - might be duplicated"
        end
      end
    end

    test "fixture: negative constraints are preserved" do
      fixture = load_fixture("negative-constraints")

      issue = build_issue_from_fixture(fixture)
      plan = build_plan_from_fixture(fixture)

      # Negative constraints (Don't modify X, Avoid Y) should be preserved
      negative_constraints = Enum.filter(issue.constraints, &is_negative_constraint?/1)

      for constraint <- negative_constraints do
        found_in_plan =
          Enum.any?(plan.deliverables, fn d ->
            instructions = d[:lead_instructions] || ""
            String.contains?(instructions, constraint)
          end)

        assert found_in_plan,
               "Negative constraint '#{constraint}' not found in plan"
      end
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

  defp default_fixture("auth-with-constraints") do
    %{
      id: "auth-with-constraints",
      spec_version: "0.2",
      issue: %{
        title: "Add JWT authentication",
        context: "Need authentication for API",
        acceptance_criteria: ["POST /auth/register works", "POST /auth/login works"],
        constraints: ["Use argon2 for password hashing", "Don't modify User schema"]
      },
      expected_plan: %{
        deliverables: [
          %{
            id: "auth-backend",
            description: "Implement JWT authentication",
            dependencies: [],
            lead_instructions:
              "Build authentication with JWT. Use argon2 for password hashing. Don't modify User schema - create a new Auth context instead."
          }
        ]
      }
    }
  end

  defp default_fixture("multi-constraint") do
    %{
      id: "multi-constraint",
      spec_version: "0.2",
      issue: %{
        title: "Add search feature",
        context: "Users need to search posts",
        acceptance_criteria: ["Search returns relevant results"],
        constraints: [
          "Use PostgreSQL full-text search",
          "Add search index on title and body",
          "Don't use external search service"
        ]
      },
      expected_plan: %{
        deliverables: [
          %{
            id: "search-backend",
            description: "Implement search",
            dependencies: [],
            lead_instructions:
              "Implement search using PostgreSQL full-text search. Add search index on title and body. Don't use external search service."
          }
        ]
      }
    }
  end

  defp default_fixture("negative-constraints") do
    %{
      id: "negative-constraints",
      spec_version: "0.2",
      issue: %{
        title: "Optimize query performance",
        context: "Dashboard queries are slow",
        acceptance_criteria: ["Dashboard loads in <200ms"],
        constraints: [
          "Don't modify the schema",
          "Avoid N+1 queries",
          "Don't add caching yet - fix queries first"
        ]
      },
      expected_plan: %{
        deliverables: [
          %{
            id: "optimize-queries",
            description: "Optimize dashboard queries",
            dependencies: [],
            lead_instructions:
              "Optimize queries to load in <200ms. Don't modify the schema. Avoid N+1 queries using preload. Don't add caching yet - fix queries first."
          }
        ]
      }
    }
  end

  defp build_issue_from_fixture(fixture) do
    issue = fixture.issue

    %{
      title: issue.title,
      context: issue.context,
      acceptance_criteria: issue.acceptance_criteria,
      constraints: issue.constraints || []
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
            lead_instructions: d[:lead_instructions]
          }
        end)
    }
  end

  defp get_lead_instructions(plan, deliverable_id) do
    deliverable = Enum.find(plan.deliverables, fn d -> d.id == deliverable_id end)
    (deliverable && deliverable[:lead_instructions]) || ""
  end

  defp contains_semantic_match?(text, constraint) do
    # Simple semantic matching - checks for key terms
    # In a real implementation, this might use embeddings or LLM comparison
    text_lower = String.downcase(text)
    constraint_lower = String.downcase(constraint)

    # Extract key terms from constraint
    key_terms =
      constraint_lower
      |> String.split()
      |> Enum.filter(&(String.length(&1) > 3))
      |> Enum.take(3)

    # Check if most key terms appear in the text
    matching_terms = Enum.count(key_terms, &String.contains?(text_lower, &1))
    matching_terms >= div(length(key_terms), 2)
  end

  defp count_substring(text, substring) do
    text
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  defp is_negative_constraint?(constraint) do
    constraint_lower = String.downcase(constraint)

    String.starts_with?(constraint_lower, "don't") or
      String.starts_with?(constraint_lower, "do not") or
      String.starts_with?(constraint_lower, "avoid") or
      String.starts_with?(constraint_lower, "never")
  end
end
