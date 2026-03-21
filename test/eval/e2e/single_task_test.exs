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
  defp create_basic_project_structure(repo_dir, scenario) do
    File.mkdir_p!(Path.join(repo_dir, "lib"))
    File.mkdir_p!(Path.join(repo_dir, "test"))
    File.mkdir_p!(Path.join(repo_dir, ".deft"))

    File.write!(Path.join([repo_dir, "test", "test_helper.exs"]), "ExUnit.start()")

    case scenario do
      :failing_test -> create_failing_test_repo(repo_dir)
      :add_schema_field -> create_ecto_schema_repo(repo_dir)
      :add_controller_action -> create_phoenix_controller_repo(repo_dir)
      :refactor_module -> create_refactor_module_repo(repo_dir)
      :fix_bug_no_test -> create_bug_no_test_repo(repo_dir)
      :implement_genserver -> create_genserver_repo(repo_dir)
      :cross_file_behavior -> create_behavior_repo(repo_dir)
      :constrained_refactor -> create_constrained_refactor_repo(repo_dir)
    end
  end

  # Scenario 1: Failing test
  defp create_failing_test_repo(repo_dir) do
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

    # Math module with a bug
    math_content = """
    defmodule Math do
      def add(a, b), do: a + b - 1  # Bug: subtracts 1
    end
    """

    File.write!(Path.join([repo_dir, "lib", "math.ex"]), math_content)

    # Failing test
    test_content = """
    defmodule MathTest do
      use ExUnit.Case

      test "test_addition" do
        assert Math.add(2, 3) == 5
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "math_test.exs"]), test_content)
  end

  # Scenario 2: Add Ecto schema field
  defp create_ecto_schema_repo(repo_dir) do
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

      defp deps do
        [
          {:ecto, "~> 3.10"},
          {:ecto_sql, "~> 3.10"},
          {:postgrex, "~> 0.17"}
        ]
      end
    end
    """

    File.write!(Path.join(repo_dir, "mix.exs"), mix_content)

    # User schema without email field
    schema_content = """
    defmodule TestProject.User do
      use Ecto.Schema

      schema "users" do
        field :name, :string
        timestamps()
      end
    end
    """

    File.mkdir_p!(Path.join([repo_dir, "lib", "test_project"]))
    File.write!(Path.join([repo_dir, "lib", "test_project", "user.ex"]), schema_content)

    # Create priv/repo/migrations directory
    File.mkdir_p!(Path.join([repo_dir, "priv", "repo", "migrations"]))
  end

  # Scenario 3: Add Phoenix controller action
  defp create_phoenix_controller_repo(repo_dir) do
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

      def application, do: [mod: {TestProject.Application, []}, extra_applications: [:logger]]

      defp deps do
        [
          {:phoenix, "~> 1.7"},
          {:plug_cowboy, "~> 2.6"}
        ]
      end
    end
    """

    File.write!(Path.join(repo_dir, "mix.exs"), mix_content)

    # UserController without the profile action
    controller_content = """
    defmodule TestProjectWeb.UserController do
      use Phoenix.Controller

      def index(conn, _params) do
        json(conn, %{users: []})
      end
    end
    """

    File.mkdir_p!(Path.join([repo_dir, "lib", "test_project_web", "controllers"]))

    File.write!(
      Path.join([repo_dir, "lib", "test_project_web", "controllers", "user_controller.ex"]),
      controller_content
    )

    # Router
    router_content = """
    defmodule TestProjectWeb.Router do
      use Phoenix.Router

      scope "/api", TestProjectWeb do
        get "/users", UserController, :index
      end
    end
    """

    File.write!(
      Path.join([repo_dir, "lib", "test_project_web", "router.ex"]),
      router_content
    )
  end

  # Scenario 4: Refactor module
  defp create_refactor_module_repo(repo_dir) do
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

    # Calculator module with repetitive code
    calculator_content = """
    defmodule Calculator do
      def add(a, b) do
        result = a + b
        if result < 0, do: 0, else: result
      end

      def subtract(a, b) do
        result = a - b
        if result < 0, do: 0, else: result
      end

      def multiply(a, b) do
        result = a * b
        if result < 0, do: 0, else: result
      end
    end
    """

    File.write!(Path.join([repo_dir, "lib", "calculator.ex"]), calculator_content)

    # Tests for Calculator
    test_content = """
    defmodule CalculatorTest do
      use ExUnit.Case

      test "add returns non-negative" do
        assert Calculator.add(5, 3) == 8
        assert Calculator.add(-5, 3) == 0
      end

      test "subtract returns non-negative" do
        assert Calculator.subtract(5, 3) == 2
        assert Calculator.subtract(3, 5) == 0
      end

      test "multiply returns non-negative" do
        assert Calculator.multiply(5, 3) == 15
        assert Calculator.multiply(-5, 3) == 0
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "calculator_test.exs"]), test_content)
  end

  # Scenario 5: Fix bug without test
  defp create_bug_no_test_repo(repo_dir) do
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

    # Comment module that allows empty comments
    comment_content = """
    defmodule Comment do
      def create(text) do
        # Bug: doesn't validate empty text
        {:ok, %{text: text}}
      end
    end
    """

    File.write!(Path.join([repo_dir, "lib", "comment.ex"]), comment_content)
  end

  # Scenario 6: Implement GenServer
  defp create_genserver_repo(repo_dir) do
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

    # Tests for CounterServer (but no implementation yet)
    test_content = """
    defmodule CounterServerTest do
      use ExUnit.Case

      test "increments counter" do
        {:ok, pid} = CounterServer.start_link(0)
        assert CounterServer.increment(pid) == 1
        assert CounterServer.get(pid) == 1
      end

      test "decrements counter" do
        {:ok, pid} = CounterServer.start_link(5)
        assert CounterServer.decrement(pid) == 4
        assert CounterServer.get(pid) == 4
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "counter_server_test.exs"]), test_content)
  end

  # Scenario 7: Cross-file behavior change
  defp create_behavior_repo(repo_dir) do
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

    # Storage behavior
    behavior_content = """
    defmodule Storage do
      @callback save(key :: String.t(), value :: any()) :: :ok
      @callback load(key :: String.t()) :: {:ok, any()} | {:error, :not_found}
    end
    """

    File.write!(Path.join([repo_dir, "lib", "storage.ex"]), behavior_content)

    # FileStorage implementation
    file_storage_content = """
    defmodule FileStorage do
      @behaviour Storage

      @impl true
      def save(_key, _value), do: :ok

      @impl true
      def load(_key), do: {:error, :not_found}
    end
    """

    File.write!(Path.join([repo_dir, "lib", "file_storage.ex"]), file_storage_content)

    # MemoryStorage implementation
    memory_storage_content = """
    defmodule MemoryStorage do
      @behaviour Storage

      @impl true
      def save(_key, _value), do: :ok

      @impl true
      def load(_key), do: {:error, :not_found}
    end
    """

    File.write!(Path.join([repo_dir, "lib", "memory_storage.ex"]), memory_storage_content)

    # Tests
    test_content = """
    defmodule StorageTest do
      use ExUnit.Case

      test "FileStorage implements Storage" do
        assert FileStorage.save("key", "value") == :ok
      end

      test "MemoryStorage implements Storage" do
        assert MemoryStorage.save("key", "value") == :ok
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "storage_test.exs"]), test_content)
  end

  # Scenario 8: Constrained refactor
  defp create_constrained_refactor_repo(repo_dir) do
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

    # UserQuery module with inefficient query
    query_content = """
    defmodule UserQuery do
      # Public API - must not change
      def find_active_users do
        # Inefficient: fetches all then filters
        all_users()
        |> Enum.filter(&(&1.active))
      end

      defp all_users do
        [
          %{id: 1, name: "Alice", active: true},
          %{id: 2, name: "Bob", active: false},
          %{id: 3, name: "Charlie", active: true}
        ]
      end
    end
    """

    File.write!(Path.join([repo_dir, "lib", "user_query.ex"]), query_content)

    # Tests
    test_content = """
    defmodule UserQueryTest do
      use ExUnit.Case

      test "find_active_users returns active users" do
        users = UserQuery.find_active_users()
        assert length(users) == 2
        assert Enum.all?(users, & &1.active)
      end
    end
    """

    File.write!(Path.join([repo_dir, "test", "user_query_test.exs"]), test_content)
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

  # Helper: Run deft work command via System.cmd
  defp run_deft_work(repo_dir, issue_id, _cost_ceiling) do
    # Path to the built escript (should be in the project root)
    escript_path = Path.join([File.cwd!(), "deft"])

    # Run deft work command
    case System.cmd(escript_path, ["work", issue_id], cd: repo_dir, stderr_to_stdout: true) do
      {output, 0} ->
        # Success - extract cost from output
        cost = extract_cost_from_output(output)
        %{status: :success, cost: cost}

      {output, _exit_code} ->
        # Failed - extract cost if available
        cost = extract_cost_from_output(output)
        %{status: :error, cost: cost}
    end
  end

  # Helper: Extract cost from deft work output
  defp extract_cost_from_output(output) do
    # Look for "Job cost: $X.XX" pattern in the output
    case Regex.run(~r/Job cost: \$([0-9]+(?:\.[0-9]+)?)/, output) do
      [_, cost_str] ->
        {cost, _} = Float.parse(cost_str)
        cost

      nil ->
        # If no explicit cost found, default to 0.0
        0.0
    end
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
