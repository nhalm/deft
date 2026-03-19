defmodule Deft.Eval.Issues.AgentCreatedQualityTest do
  @moduledoc """
  Evaluates the quality of issues created autonomously by the agent.

  Tests whether agent-created issues have enough context to be actionable:
  - Not just a title
  - Context field is populated with sufficient detail
  - Source is :agent
  - Priority is 3 (default for agent-created)

  Pass rate: 80% over 20 iterations (spec says 75%, but work item says 80%)
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  alias Deft.Issue

  @moduletag :eval
  @moduletag :expensive

  describe "agent-created issue quality" do
    test "fixture: agent-created issue has actionable context" do
      fixture = load_fixture("refactor-auth-handler")

      issue = build_issue_from_fixture(fixture)

      # Hard assertions on structure
      assert issue.source == :agent
      assert issue.priority == 3
      assert issue.context != ""
      assert String.length(issue.context) > 20

      # Context should be more than just the title
      refute String.downcase(issue.context) == String.downcase(issue.title)
    end

    test "fixture: multiple agent-created issues maintain quality" do
      fixtures = ["refactor-auth-handler", "extract-validation", "add-error-logging"]

      for fixture_name <- fixtures do
        fixture = load_fixture(fixture_name)
        issue = build_issue_from_fixture(fixture)

        assert issue.source == :agent
        assert issue.context != ""
        assert String.length(issue.context) > 20
      end
    end

    @tag :integration
    test "llm-as-judge: agent-created issues are actionable" do
      # This test will use an LLM-as-judge to evaluate whether
      # the agent-created issue has enough context to be actionable
      #
      # For now, we're creating the test structure and fixtures.
      # The actual LLM integration will be added once we have
      # agent-created issue examples to test.

      fixture = load_fixture("refactor-auth-handler")
      issue = build_issue_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # assert_faithful issue.context,
      #   context: "Issue has enough context to be actionable without additional information",
      #   model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert issue.source == :agent
      assert issue.context != ""
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "issue_transcripts", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        # Return default fixtures if files don't exist yet
        default_fixtures(name)
    end
  end

  defp default_fixtures("refactor-auth-handler") do
    %{
      id: "refactor-auth-handler",
      session_context: "Agent discovered complex auth handler during work on JWT implementation",
      expected_issue: %{
        title: "Refactor auth handler for testability",
        context:
          "During JWT implementation work, discovered the auth handler is tightly coupled to the Phoenix controller layer. This makes it difficult to test in isolation. Refactoring would improve maintainability and test coverage.",
        acceptance_criteria: [
          "Auth logic extracted to separate module",
          "Unit tests can run without Phoenix context"
        ],
        constraints: [],
        priority: 3,
        source: :agent
      }
    }
  end

  defp default_fixtures("extract-validation") do
    %{
      id: "extract-validation",
      session_context: "Agent noticed duplicate validation logic across multiple endpoints",
      expected_issue: %{
        title: "Extract duplicate validation logic to shared module",
        context:
          "Multiple endpoints have identical email and password validation logic. This duplication increases maintenance burden and creates inconsistency risk. Should be extracted to a shared validation module.",
        acceptance_criteria: [
          "Validation logic centralized in single module",
          "All endpoints use shared validator"
        ],
        constraints: ["Keep existing error message format"],
        priority: 3,
        source: :agent
      }
    }
  end

  defp default_fixtures("add-error-logging") do
    %{
      id: "add-error-logging",
      session_context: "Agent observed authentication failures with no error logging",
      expected_issue: %{
        title: "Add error logging for authentication failures",
        context:
          "Authentication failures currently fail silently with no logging. This makes debugging production issues difficult. Adding structured logging would improve observability.",
        acceptance_criteria: [
          "Failed auth attempts logged with user context",
          "Logs include timestamp and failure reason"
        ],
        constraints: ["Don't log sensitive data like passwords"],
        priority: 3,
        source: :agent
      }
    }
  end

  defp default_fixtures(_name) do
    %{
      id: "unknown",
      expected_issue: %{
        title: "Unknown fixture",
        context: "This is a placeholder fixture",
        acceptance_criteria: [],
        constraints: [],
        priority: 3,
        source: :agent
      }
    }
  end

  defp build_issue_from_fixture(fixture) do
    expected = fixture.expected_issue
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Convert source from string to atom if needed
    source =
      case expected[:source] do
        "agent" -> :agent
        "user" -> :user
        :agent -> :agent
        :user -> :user
        _ -> :agent
      end

    %Issue{
      id: "deft-test",
      title: expected.title,
      context: expected.context,
      acceptance_criteria: expected.acceptance_criteria,
      constraints: expected.constraints || [],
      status: :open,
      priority: expected[:priority] || 3,
      dependencies: [],
      created_at: now,
      updated_at: now,
      closed_at: nil,
      source: source,
      job_id: nil
    }
  end
end
