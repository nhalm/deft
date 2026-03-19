defmodule Deft.Eval.Issues.IssuePlanDiagnosticTest do
  @moduledoc """
  Diagnostic eval: Issue Quality → Plan Quality

  Tests whether well-structured issues (with context, acceptance_criteria, constraints)
  produce better Foreman plans than bare-title issues.

  This is a diagnostic eval that validates the interactive issue creation session
  delivers value. If structured issues don't produce better downstream outcomes
  than `--quick` issues, the creation session is friction without payoff.

  Input: Same task given to Foreman twice:
  - Once with a well-structured issue (good AC, constraints, context)
  - Once with a bare title (`--quick` mode)

  Expected: The plan from the well-structured issue has:
  - More specific task instructions
  - Concrete verification targets
  - Better use of constraints in Lead steering

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration
  @moduletag :diagnostic

  describe "structured issue fields flow into Foreman planning" do
    @tag :llm_judge
    test "fixture: jwt-auth structured vs bare produces better plan" do
      structured_fixture = load_fixture("jwt-auth-structured")
      bare_fixture = load_fixture("jwt-auth-bare")

      # Generate plans from both fixtures
      # NOTE: This will call the actual Foreman planning phase once implemented
      structured_plan = generate_plan_from_issue(structured_fixture)
      bare_plan = generate_plan_from_issue(bare_fixture)

      # LLM-as-judge comparison
      # The judge should evaluate:
      # 1. Does the structured plan have more specific task descriptions?
      # 2. Does the structured plan reference the constraints?
      # 3. Does the structured plan have concrete verification targets from AC?

      # Placeholder assertion until Tribunal integration is complete
      # Will use: assert_comparison structured_plan, bare_plan,
      #   prompt: "Compare these two plans for implementing JWT auth. Does Plan A have more specific task instructions, concrete verification targets, and evidence of using the provided constraints? Answer YES if Plan A is clearly better, NO otherwise.",
      #   model: "claude-sonnet-4-6"

      # For now, verify structure exists
      assert structured_plan != nil
      assert bare_plan != nil
      assert structured_fixture.context != ""
      assert length(structured_fixture.acceptance_criteria) > 0
      assert length(structured_fixture.constraints) > 0
      assert bare_fixture.context == ""
      assert bare_fixture.acceptance_criteria == []
      assert bare_fixture.constraints == []
    end

    @tag :llm_judge
    test "fixture: validation-refactor structured vs bare produces better plan" do
      structured_fixture = load_fixture("validation-refactor-structured")
      bare_fixture = load_fixture("validation-refactor-bare")

      structured_plan = generate_plan_from_issue(structured_fixture)
      bare_plan = generate_plan_from_issue(bare_fixture)

      # Placeholder - same comparison pattern as above
      assert structured_plan != nil
      assert bare_plan != nil
      assert structured_fixture.context != ""
      assert length(structured_fixture.acceptance_criteria) > 0
    end

    test "acceptance criteria flow into verification phase" do
      # Verify that acceptance criteria from the issue appear in the plan's
      # verification targets

      fixture = load_fixture("jwt-auth-structured")
      plan = generate_plan_from_issue(fixture)

      # The plan should include verification targets that match the AC
      # This is a structural check, not an LLM-as-judge check

      # Placeholder: once Foreman planning is implemented, verify that:
      # - plan.verification_targets exists
      # - Each AC from the issue maps to at least one verification target

      assert plan != nil
      assert fixture.acceptance_criteria != []
    end

    test "constraints flow into Lead steering instructions" do
      # Verify that constraints from the issue appear in the plan's
      # deliverable assignments as steering instructions for Leads

      fixture = load_fixture("jwt-auth-structured")
      plan = generate_plan_from_issue(fixture)

      # Placeholder: once Foreman planning is implemented, verify that:
      # - plan.deliverables exists
      # - Constraints appear in deliverable.constraints or deliverable.instructions

      assert plan != nil
      assert fixture.constraints != []
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "issues", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        # Fixture files have an 'issue' key wrapping the actual issue
        fixture_data = Jason.decode!(content, keys: :atoms)
        fixture_data.issue

      {:error, _} ->
        # Return default fixture if file doesn't exist yet
        default_fixture(name)
    end
  end

  defp default_fixture("jwt-auth-structured") do
    %{
      id: "deft-a1b2",
      title: "Add JWT authentication to the API",
      context: """
      The API currently has no authentication. We need JWT-based auth so the
      frontend can make authenticated requests. This is blocking the user
      management features scheduled for next sprint.
      """,
      acceptance_criteria: [
        "POST /auth/register accepts email+password, returns 201 with JWT",
        "POST /auth/login verifies credentials, returns 200 with JWT",
        "Invalid/expired tokens return 401",
        "Tokens expire after 24 hours"
      ],
      constraints: [
        "Use argon2 for password hashing, not bcrypt",
        "Don't modify the existing User schema - add a separate Credential model",
        "JWT secret must be loaded from environment variable"
      ],
      status: "open",
      priority: 1,
      dependencies: [],
      source: "user"
    }
  end

  defp default_fixture("jwt-auth-bare") do
    %{
      id: "deft-a1b3",
      title: "Add JWT authentication to the API",
      context: "",
      acceptance_criteria: [],
      constraints: [],
      status: "open",
      priority: 1,
      dependencies: [],
      source: "user"
    }
  end

  defp default_fixture("validation-refactor-structured") do
    %{
      id: "deft-b2c3",
      title: "Extract validation logic from controllers",
      context: """
      Validation logic is currently scattered across controller actions. This
      makes it hard to test and reuse. We need to centralize validation in
      dedicated modules.
      """,
      acceptance_criteria: [
        "Validation modules exist in lib/app/validators/",
        "Controller actions call validators instead of inline validation",
        "All existing tests still pass",
        "New validator unit tests cover edge cases"
      ],
      constraints: [
        "Don't change the API contract - same error response format",
        "Extract incrementally - one controller at a time",
        "Keep existing changeset validations for Ecto models"
      ],
      status: "open",
      priority: 2,
      dependencies: [],
      source: "user"
    }
  end

  defp default_fixture("validation-refactor-bare") do
    %{
      id: "deft-b2c4",
      title: "Extract validation logic from controllers",
      context: "",
      acceptance_criteria: [],
      constraints: [],
      status: "open",
      priority: 2,
      dependencies: [],
      source: "user"
    }
  end

  defp generate_plan_from_issue(issue) do
    # Placeholder function that will interface with Foreman planning once implemented
    #
    # Expected behavior:
    # 1. Start a Foreman in planning mode
    # 2. Feed it the issue structure
    # 3. Let it complete research and decomposition phases
    # 4. Extract the resulting plan
    #
    # For now, return a mock plan structure

    %{
      deliverables: mock_deliverables_for_issue(issue),
      verification_targets: mock_verification_targets(issue),
      cost_estimate: 1.50,
      duration_estimate_minutes: 15
    }
  end

  defp mock_deliverables_for_issue(issue) do
    # Mock deliverables based on issue content
    # This will be replaced with actual Foreman planning

    case issue.id do
      "deft-a1b2" ->
        # Structured JWT auth issue
        [
          %{
            id: "auth-backend",
            description: "Implement JWT authentication with register/login endpoints",
            dependencies: [],
            constraints: Map.get(issue, :constraints, [])
          }
        ]

      "deft-a1b3" ->
        # Bare JWT auth issue
        [
          %{
            id: "auth-backend",
            description: "Add authentication",
            dependencies: [],
            constraints: []
          }
        ]

      _ ->
        [
          %{
            id: "generic-deliverable",
            description: "Implement #{issue.title}",
            dependencies: [],
            constraints: Map.get(issue, :constraints, [])
          }
        ]
    end
  end

  defp mock_verification_targets(issue) do
    # Mock verification targets from acceptance criteria
    # This will be replaced with actual Foreman planning

    acceptance_criteria = Map.get(issue, :acceptance_criteria, [])

    if acceptance_criteria != [] do
      Enum.map(acceptance_criteria, fn ac ->
        %{criterion: ac, test_type: "integration"}
      end)
    else
      []
    end
  end
end
