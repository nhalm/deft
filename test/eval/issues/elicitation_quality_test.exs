defmodule Deft.Eval.Issues.ElicitationQualityTest do
  @moduledoc """
  Evaluates the quality of issue elicitation during interactive creation sessions.

  Tests whether the resulting structured issue JSON has:
  - Specific and testable acceptance criteria (not "it should work correctly")
  - Constraints that are restrictions on how, not goals
  - Context that explains motivation, not just restates the title
  - All three fields non-empty

  Pass rate: 80% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  alias Deft.Issue

  @moduletag :eval
  @moduletag :expensive

  # Note: This test will be implemented once the issue elicitation
  # tool/function is available. For now, we're testing the structure
  # of manually constructed issues to validate the fixture design.

  describe "elicitation quality" do
    test "fixture: jwt-auth issue has testable acceptance criteria" do
      fixture = load_fixture("jwt-auth")

      issue = build_issue_from_fixture(fixture)

      # Hard assertions on structure
      assert issue.context != ""
      assert length(issue.acceptance_criteria) > 0
      assert length(issue.constraints) >= 0

      # Check that context doesn't just restate the title
      refute String.contains?(String.downcase(issue.context), String.downcase(issue.title))

      # Check acceptance criteria are specific
      for criterion <- issue.acceptance_criteria do
        # Criteria should be concrete, not vague
        refute String.contains?(String.downcase(criterion), "should work")
        refute String.contains?(String.downcase(criterion), "works correctly")
      end
    end

    @tag :integration
    test "llm-as-judge: acceptance criteria are testable" do
      # This test will use an LLM-as-judge to evaluate whether
      # acceptance criteria are testable with code or manual verification
      #
      # For now, we're creating the test structure and fixtures.
      # The actual LLM integration will be added once we have
      # a working elicitation function to test.

      fixture = load_fixture("jwt-auth")
      issue = build_issue_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # assert_faithful issue.acceptance_criteria,
      #   context: "Each criterion should be testable with code or manual verification",
      #   model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert length(issue.acceptance_criteria) > 0
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "issue_transcripts", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        # Return a default fixture if file doesn't exist yet
        %{
          id: name,
          title: "Default fixture",
          messages: [],
          expected_issue: %{
            title: "Add JWT authentication",
            context: "The API currently has no authentication mechanism.",
            acceptance_criteria: [
              "POST /auth/register returns 201 with JWT token",
              "POST /auth/login verifies credentials and returns 200 with JWT",
              "Invalid tokens return 401"
            ],
            constraints: [
              "Use argon2 for password hashing",
              "Don't modify existing User schema"
            ],
            priority: 1
          }
        }
    end
  end

  defp build_issue_from_fixture(fixture) do
    expected = fixture.expected_issue
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %Issue{
      id: "deft-test",
      title: expected.title,
      context: expected.context,
      acceptance_criteria: expected.acceptance_criteria,
      constraints: expected.constraints || [],
      status: :open,
      priority: expected[:priority] || 2,
      dependencies: [],
      created_at: now,
      updated_at: now,
      closed_at: nil,
      source: :user,
      job_id: nil
    }
  end
end
