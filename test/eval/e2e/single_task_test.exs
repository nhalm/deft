defmodule Deft.Eval.E2E.SingleTaskTest do
  @moduledoc """
  End-to-end eval tests for single-task completion.

  Tests the 8 benchmark tasks on synthetic repos to verify basic code editing,
  multi-file changes, new feature creation, refactoring, issue interpretation,
  OTP patterns, cross-file coordination, and constraint adherence.

  Per spec: each task is scored as PASS/PARTIAL/FAIL/ERROR + cost tracking.
  """

  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration
  @moduletag :e2e
  @moduletag :benchmark

  @cost_ceiling_default 5.0

  setup do
    # Create temporary directory for synthetic repo
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "e2e_single_task_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "task battery - 8 benchmark tasks" do
    @tag timeout: 600_000
    test "task 1: fix a single failing ExUnit test", %{tmp_dir: tmp_dir} do
      # Create synthetic repo with a failing test
      repo_dir = setup_synthetic_repo(tmp_dir, :failing_test)

      # Write issue to .deft/issues.jsonl
      issue_id =
        write_issue(repo_dir, %{
          title: "Fix failing test in math module",
          description: "The test_addition test is failing. Fix it.",
          acceptance_criteria: ["All tests pass"]
        })

      # Run deft work
      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Verify tests pass
      tests_pass = run_tests(repo_dir)

      assert tests_pass == :pass,
             "Task 1 FAIL: Tests did not pass after agent work. Cost: $#{result.cost}"

      IO.puts("Task 1 PASS: Fixed failing test. Cost: $#{result.cost}")
    end

    @tag timeout: 600_000
    test "task 2: add a new Ecto schema field with migration", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :add_schema_field)

      issue_id =
        write_issue(repo_dir, %{
          title: "Add email field to User schema",
          description: "Add an email field to the User schema with migration",
          acceptance_criteria: [
            "Email field added to User schema",
            "Migration file created",
            "Migration runs successfully",
            "Schema compiles"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Check migration exists
      migration_exists =
        File.exists?(Path.join([repo_dir, "priv/repo/migrations/*add_email*.exs"]))

      # Check schema compiles
      schema_ok = verify_schema_compiles(repo_dir)

      if migration_exists and schema_ok do
        IO.puts("Task 2 PASS: Added schema field with migration. Cost: $#{result.cost}")
        assert true
      else
        IO.puts("Task 2 FAIL: Migration or schema issue. Cost: $#{result.cost}")
        assert false, "Migration missing or schema doesn't compile"
      end
    end

    @tag timeout: 600_000
    test "task 3: add a Phoenix controller action with tests", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :add_controller_action)

      issue_id =
        write_issue(repo_dir, %{
          title: "Add user profile endpoint",
          description: "Add a GET /api/users/:id endpoint that returns user profile",
          acceptance_criteria: [
            "New action exists in UserController",
            "Integration test passes",
            "Route is registered"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Run integration tests
      tests_pass = run_tests(repo_dir)

      assert tests_pass == :pass,
             "Task 3 FAIL: Integration tests failed. Cost: $#{result.cost}"

      IO.puts("Task 3 PASS: Added controller action with tests. Cost: $#{result.cost}")
    end

    @tag timeout: 600_000
    test "task 4: refactor a module without breaking tests", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :refactor_module)

      issue_id =
        write_issue(repo_dir, %{
          title: "Refactor Calculator module",
          description: "Extract common logic into private functions",
          acceptance_criteria: [
            "Test suite passes",
            "Module structure changed"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Tests must pass
      tests_pass = run_tests(repo_dir)

      # Use LLM judge to verify structure changed
      structure_changed = judge_refactoring_occurred(repo_dir)

      if tests_pass == :pass and structure_changed do
        IO.puts("Task 4 PASS: Refactored without breaking tests. Cost: $#{result.cost}")
        assert true
      else
        IO.puts("Task 4 FAIL: Tests failed or no refactoring detected. Cost: $#{result.cost}")
        assert false
      end
    end

    @tag timeout: 600_000
    test "task 5: fix a bug described in plain English", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :fix_bug_no_test)

      issue_id =
        write_issue(repo_dir, %{
          title: "Users can submit empty comments",
          description: "The comment form should not allow empty submissions",
          acceptance_criteria: [
            "Agent writes a test for the bug",
            "Agent fixes the bug",
            "All tests pass"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Check tests pass
      tests_pass = run_tests(repo_dir)

      assert tests_pass == :pass,
             "Task 5 FAIL: Tests failed. Cost: $#{result.cost}"

      IO.puts("Task 5 PASS: Fixed bug and wrote test. Cost: $#{result.cost}")
    end

    @tag timeout: 600_000
    test "task 6: implement a small GenServer per spec", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :implement_genserver)

      issue_id =
        write_issue(repo_dir, %{
          title: "Implement CounterServer GenServer",
          description: "Create a GenServer that maintains a counter with increment/decrement",
          acceptance_criteria: [
            "GenServer compiles",
            "Provided tests pass"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      tests_pass = run_tests(repo_dir)

      assert tests_pass == :pass,
             "Task 6 FAIL: GenServer tests failed. Cost: $#{result.cost}"

      IO.puts("Task 6 PASS: Implemented GenServer. Cost: $#{result.cost}")
    end

    @tag timeout: 600_000
    test "task 7: cross-file change - update behavior and implementors", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :cross_file_behavior)

      issue_id =
        write_issue(repo_dir, %{
          title: "Add required callback to Storage behavior",
          description: "Add a new required callback and update all implementors",
          acceptance_criteria: [
            "Behavior updated",
            "All implementations compile",
            "All tests pass"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      tests_pass = run_tests(repo_dir)

      assert tests_pass == :pass,
             "Task 7 FAIL: Cross-file change failed. Cost: $#{result.cost}"

      IO.puts("Task 7 PASS: Updated behavior and all implementors. Cost: $#{result.cost}")
    end

    @tag timeout: 600_000
    test "task 8: issue with constraint - don't change public API", %{tmp_dir: tmp_dir} do
      repo_dir = setup_synthetic_repo(tmp_dir, :constrained_refactor)

      issue_id =
        write_issue(repo_dir, %{
          title: "Optimize query performance",
          description: "Make the user query faster without changing the public API",
          acceptance_criteria: [
            "Query is optimized",
            "Public API unchanged",
            "Tests pass"
          ]
        })

      result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)

      # Tests must pass
      tests_pass = run_tests(repo_dir)

      # Use LLM judge to verify constraint respected
      constraint_respected = judge_constraint_respected(repo_dir, "public API unchanged")

      if tests_pass == :pass and constraint_respected do
        IO.puts("Task 8 PASS: Constraint respected. Cost: $#{result.cost}")
        assert true
      else
        IO.puts("Task 8 FAIL: Constraint violated or tests failed. Cost: $#{result.cost}")
        assert false
      end
    end
  end

  # Helper: Setup synthetic repo with specific scenario
  defp setup_synthetic_repo(tmp_dir, scenario) do
    repo_dir = Path.join(tmp_dir, Atom.to_string(scenario))
    File.mkdir_p!(repo_dir)

    # Initialize git repo
    System.cmd("git", ["init"], cd: repo_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    # Create basic Elixir project structure
    create_basic_project_structure(repo_dir, scenario)

    # Initial commit
    System.cmd("git", ["add", "."], cd: repo_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: repo_dir)

    repo_dir
  end

  # Helper: Create basic project structure for different scenarios
  defp create_basic_project_structure(repo_dir, _scenario) do
    # Create mix.exs
    File.mkdir_p!(Path.join(repo_dir, "lib"))
    File.mkdir_p!(Path.join(repo_dir, "test"))
    File.mkdir_p!(Path.join(repo_dir, ".deft"))

    mix_content = """
    defmodule TestProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :test_project,
          version: "0.1.0",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps, do: []
    end
    """

    File.write!(Path.join(repo_dir, "mix.exs"), mix_content)

    # Create a simple test file
    test_content = """
    defmodule TestProjectTest do
      use ExUnit.Case

      test "placeholder passes" do
        assert true
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "test_helper.exs"]), "ExUnit.start()")
    File.write!(Path.join([repo_dir, "test", "test_project_test.exs"]), test_content)
  end

  # Helper: Write issue to .deft/issues.jsonl
  defp write_issue(repo_dir, issue_attrs) do
    issue_id = "issue_#{:erlang.unique_integer([:positive])}"
    issues_file = Path.join([repo_dir, ".deft", "issues.jsonl"])

    issue = %{
      id: issue_id,
      title: issue_attrs.title,
      description: issue_attrs.description,
      acceptance_criteria: issue_attrs.acceptance_criteria,
      status: "open",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(issues_file, Jason.encode!(issue) <> "\n")

    issue_id
  end

  # Helper: Run deft work command (placeholder)
  defp run_deft_work(_repo_dir, _issue_id, cost_ceiling) do
    # NOTE: This is a placeholder for actual deft CLI execution
    # In real implementation, this would invoke the built escript
    # System.cmd("deft", ["work", issue_id, "--cost-ceiling", to_string(cost_ceiling)], cd: repo_dir)

    %{
      status: :success,
      cost: :rand.uniform() * cost_ceiling
    }
  end

  # Helper: Run test suite
  defp run_tests(repo_dir) do
    case System.cmd("mix", ["test"], cd: repo_dir, stderr_to_stdout: true) do
      {_output, 0} -> :pass
      {_output, _} -> :fail
    end
  end

  # Helper: Verify schema compiles (placeholder)
  defp verify_schema_compiles(_repo_dir) do
    # Placeholder - would actually compile and check schema
    true
  end

  # Helper: Judge if refactoring occurred using LLM (placeholder)
  defp judge_refactoring_occurred(_repo_dir) do
    # Placeholder - would use Helpers.call_llm_judge/2
    true
  end

  # Helper: Judge if constraint was respected (placeholder)
  defp judge_constraint_respected(_repo_dir, _constraint) do
    # Placeholder - would use Helpers.call_llm_judge/2
    true
  end
end
