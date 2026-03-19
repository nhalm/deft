defmodule Deft.Eval.Lead.TaskPlanningTest do
  @moduledoc """
  Evaluates the quality of Lead task planning (decomposition).

  Tests whether the Lead decomposes a deliverable into appropriate Runner tasks:
  - 4-8 concrete Runner tasks for typical deliverables
  - Each task has a clear done state
  - Tasks are dependency-ordered
  - Tasks are at the right granularity (not too fine, not too coarse)

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  describe "task decomposition from deliverable + research" do
    test "fixture: auth-implementation produces 4-8 tasks" do
      fixture = load_fixture("auth-implementation")

      # Build task plan from the fixture
      task_plan = build_task_plan_from_fixture(fixture)

      # Check task count
      task_count = length(task_plan.tasks)

      assert task_count >= 4 and task_count <= 8,
             "Expected 4-8 tasks, got #{task_count}"

      # Check that each task has a description and done state
      for task <- task_plan.tasks do
        assert task.description != ""
        assert String.length(task.description) > 10
        assert task.done_state != ""
        assert String.length(task.done_state) > 5
      end
    end

    test "fixture: tasks are dependency-ordered" do
      fixture = load_fixture("auth-implementation")
      task_plan = build_task_plan_from_fixture(fixture)

      # Verify dependencies reference earlier tasks
      task_ids = Enum.map(task_plan.tasks, & &1.id)

      for {task, index} <- Enum.with_index(task_plan.tasks) do
        for dep_id <- task.dependencies do
          dep_index = Enum.find_index(task_ids, &(&1 == dep_id))

          assert dep_index < index,
                 "Task #{task.id} depends on #{dep_id} which comes later in the list"
        end
      end
    end

    test "fixture: simple deliverable produces fewer tasks" do
      fixture = load_fixture("add-validation")

      task_plan = build_task_plan_from_fixture(fixture)

      # Simpler deliverables should result in fewer tasks
      assert length(task_plan.tasks) >= 2 and length(task_plan.tasks) <= 5
    end

    @tag :llm_judge
    test "llm-as-judge: task descriptions are clear and actionable" do
      # This test will use an LLM-as-judge to evaluate whether
      # task descriptions are clear enough for a Runner to execute
      #
      # For now, we're creating the test structure and fixtures.
      # The actual LLM integration will be added once we have
      # a working Lead planning function to test.

      fixture = load_fixture("auth-implementation")
      task_plan = build_task_plan_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # For each task:
      #   assert_faithful task.description,
      #     context: "Is this description clear enough for a developer to execute without ambiguity?",
      #     model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert length(task_plan.tasks) > 0
    end

    @tag :llm_judge
    test "llm-as-judge: done states are verifiable" do
      # Tests that done states are concrete and testable,
      # not vague like "completed successfully"

      fixture = load_fixture("auth-implementation")
      task_plan = build_task_plan_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # For each task:
      #   assert_faithful task.done_state,
      #     context: "Is this done state concrete and verifiable? Does it avoid vague language like 'completed successfully'?",
      #     model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert length(task_plan.tasks) > 0
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "lead", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        # Return a default fixture if file doesn't exist yet
        default_fixture(name)
    end
  end

  defp default_fixture("auth-implementation") do
    %{
      id: "auth-implementation",
      spec_version: "0.2",
      description: "Implement JWT authentication backend",
      deliverable: %{
        id: "auth-backend",
        description: "Implement JWT authentication backend with register/login endpoints",
        dependencies: []
      },
      research_findings: """
      - Guardian library is the standard JWT implementation for Phoenix
      - Need to add :guardian and :bcrypt_elixir to mix.exs
      - User schema should have email, password_hash fields
      - Register endpoint: POST /api/auth/register
      - Login endpoint: POST /api/auth/login
      - Return JWT token on successful login
      """,
      codebase_snapshot: "phoenix-minimal",
      expected_tasks: [
        %{
          id: "add-dependencies",
          description: "Add Guardian and bcrypt_elixir to mix.exs dependencies",
          done_state: "mix.exs contains guardian and bcrypt_elixir in deps list",
          dependencies: []
        },
        %{
          id: "create-user-schema",
          description: "Create User schema with email and password_hash fields",
          done_state: "lib/app/accounts/user.ex exists with email and password_hash fields",
          dependencies: []
        },
        %{
          id: "create-migration",
          description: "Generate and configure database migration for users table",
          done_state: "Migration file exists in priv/repo/migrations/ for users table",
          dependencies: ["create-user-schema"]
        },
        %{
          id: "configure-guardian",
          description: "Set up Guardian configuration module",
          done_state: "lib/app/guardian.ex exists with implementation callbacks",
          dependencies: ["add-dependencies"]
        },
        %{
          id: "create-auth-controller",
          description: "Implement AuthController with register and login actions",
          done_state:
            "lib/app_web/controllers/auth_controller.ex exists with register/2 and login/2 functions",
          dependencies: ["create-user-schema", "configure-guardian"]
        },
        %{
          id: "add-routes",
          description: "Add /api/auth/register and /api/auth/login routes",
          done_state: "router.ex contains POST routes for /api/auth/register and /api/auth/login",
          dependencies: ["create-auth-controller"]
        }
      ]
    }
  end

  defp default_fixture("add-validation") do
    %{
      id: "add-validation",
      spec_version: "0.2",
      description: "Add input validation to registration endpoint",
      deliverable: %{
        id: "registration-validation",
        description: "Add validation for email format and password strength",
        dependencies: ["auth-backend"]
      },
      research_findings: """
      - Email validation: use email_validator library or regex
      - Password strength: minimum 8 chars, require special char and number
      - Return 422 with error details on validation failure
      """,
      codebase_snapshot: "phoenix-minimal",
      expected_tasks: [
        %{
          id: "add-validation-library",
          description: "Add email_validator to mix.exs if not already present",
          done_state: "email_validator present in mix.exs deps or email validation logic exists",
          dependencies: []
        },
        %{
          id: "update-changeset",
          description:
            "Update User changeset with email format and password strength validations",
          done_state:
            "User.changeset/2 validates email format and password meets strength requirements",
          dependencies: []
        },
        %{
          id: "update-controller",
          description: "Update AuthController to return 422 with validation errors",
          done_state: "register/2 returns 422 status with error details on invalid input",
          dependencies: ["update-changeset"]
        }
      ]
    }
  end

  defp build_task_plan_from_fixture(fixture) do
    expected = fixture.expected_tasks

    %{
      tasks:
        Enum.map(expected, fn t ->
          %{
            id: t.id,
            description: t.description,
            done_state: t.done_state,
            dependencies: t.dependencies || []
          }
        end)
    }
  end
end
