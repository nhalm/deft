defmodule Deft.Eval.E2E.MultiAgentTest do
  @moduledoc """
  End-to-end comparison of single-agent vs multi-agent orchestration.

  Runs the same benchmark tasks with both strategies to answer:
  "Does orchestration (Foreman + Leads) pay off compared to single-agent fallback?"

  Hypothesis: orchestration adds value above a complexity threshold.

  Metrics tracked:
  - Success rate (PASS/PARTIAL/FAIL/ERROR)
  - Cost per task
  - Time per task
  - Complexity threshold where orchestration starts winning
  """

  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration
  @moduletag :e2e
  @moduletag :benchmark

  @cost_ceiling_default 5.0

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "e2e_multi_agent_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "orchestration comparison" do
    @tag timeout: 1_200_000
    test "simple task: single-agent vs multi-agent", %{tmp_dir: tmp_dir} do
      # Task: Fix a single failing test (low complexity)
      task_spec = %{
        title: "Fix failing test",
        description: "Fix the failing test in math module",
        acceptance_criteria: ["All tests pass"],
        complexity: :low
      }

      # Run with single-agent mode
      single_result = run_task_with_strategy(tmp_dir, task_spec, :single_agent)

      # Run with multi-agent mode (Foreman + Lead orchestration)
      multi_result = run_task_with_strategy(tmp_dir, task_spec, :multi_agent)

      # Log results
      IO.puts("\nSimple Task Results:")

      IO.puts(
        "  Single-agent: #{single_result.status} ($#{single_result.cost}, #{single_result.time}s)"
      )

      IO.puts(
        "  Multi-agent:  #{multi_result.status} ($#{multi_result.cost}, #{multi_result.time}s)"
      )

      # For low-complexity tasks, single-agent should be competitive or better
      # (lower orchestration overhead)
      assert single_result.status == :pass or multi_result.status == :pass,
             "At least one strategy should complete the simple task"
    end

    @tag timeout: 1_200_000
    test "medium task: single-agent vs multi-agent", %{tmp_dir: tmp_dir} do
      # Task: Add Phoenix controller with tests (medium complexity)
      task_spec = %{
        title: "Add controller action",
        description: "Add GET /api/users/:id endpoint with tests",
        acceptance_criteria: [
          "New action exists",
          "Integration test passes",
          "Route registered"
        ],
        complexity: :medium
      }

      single_result = run_task_with_strategy(tmp_dir, task_spec, :single_agent)
      multi_result = run_task_with_strategy(tmp_dir, task_spec, :multi_agent)

      IO.puts("\nMedium Task Results:")

      IO.puts(
        "  Single-agent: #{single_result.status} ($#{single_result.cost}, #{single_result.time}s)"
      )

      IO.puts(
        "  Multi-agent:  #{multi_result.status} ($#{multi_result.cost}, #{multi_result.time}s)"
      )

      assert single_result.status != :error or multi_result.status != :error,
             "At least one strategy should handle medium complexity"
    end

    @tag timeout: 1_200_000
    test "complex task: single-agent vs multi-agent", %{tmp_dir: tmp_dir} do
      # Task: Cross-file behavior update (high complexity)
      task_spec = %{
        title: "Update behavior and implementors",
        description: "Add required callback to Storage behavior and update all implementors",
        acceptance_criteria: [
          "Behavior updated",
          "All implementations compile",
          "All tests pass"
        ],
        complexity: :high
      }

      single_result = run_task_with_strategy(tmp_dir, task_spec, :single_agent)
      multi_result = run_task_with_strategy(tmp_dir, task_spec, :multi_agent)

      IO.puts("\nComplex Task Results:")

      IO.puts(
        "  Single-agent: #{single_result.status} ($#{single_result.cost}, #{single_result.time}s)"
      )

      IO.puts(
        "  Multi-agent:  #{multi_result.status} ($#{multi_result.cost}, #{multi_result.time}s)"
      )

      # Hypothesis: multi-agent should win on high-complexity tasks
      # (better decomposition and coordination)
      if multi_result.status == :pass and single_result.status != :pass do
        IO.puts("\n✓ Hypothesis confirmed: orchestration helps with complex tasks")
      end

      assert multi_result.status == :pass or single_result.status == :pass,
             "At least one strategy should handle complex task"
    end

    @tag timeout: 2_400_000
    test "full battery comparison: identify complexity threshold", %{tmp_dir: tmp_dir} do
      # Run all 8 tasks with both strategies to find where orchestration starts winning
      tasks = [
        %{name: "fix_test", complexity: :low},
        %{name: "add_schema", complexity: :low},
        %{name: "add_controller", complexity: :medium},
        %{name: "refactor", complexity: :medium},
        %{name: "fix_bug", complexity: :medium},
        %{name: "genserver", complexity: :medium},
        %{name: "cross_file", complexity: :high},
        %{name: "constrained", complexity: :high}
      ]

      results =
        Enum.map(tasks, fn task ->
          single = run_synthetic_task(tmp_dir, task, :single_agent)
          multi = run_synthetic_task(tmp_dir, task, :multi_agent)

          %{
            task: task.name,
            complexity: task.complexity,
            single_agent: single,
            multi_agent: multi
          }
        end)

      # Analyze results by complexity
      by_complexity = Enum.group_by(results, & &1.complexity)

      IO.puts("\n=== Full Battery Comparison ===")

      for complexity <- [:low, :medium, :high] do
        tasks_at_level = Map.get(by_complexity, complexity, [])

        single_wins =
          Enum.count(tasks_at_level, fn r ->
            r.single_agent.status == :pass and r.multi_agent.status != :pass
          end)

        multi_wins =
          Enum.count(tasks_at_level, fn r ->
            r.multi_agent.status == :pass and r.single_agent.status != :pass
          end)

        both_pass =
          Enum.count(tasks_at_level, fn r ->
            r.single_agent.status == :pass and r.multi_agent.status == :pass
          end)

        IO.puts("\n#{complexity} complexity tasks (#{length(tasks_at_level)} total):")
        IO.puts("  Single-agent wins: #{single_wins}")
        IO.puts("  Multi-agent wins:  #{multi_wins}")
        IO.puts("  Both pass:         #{both_pass}")
      end

      # Assert that at least some tasks complete with either strategy
      total_completions =
        Enum.count(results, fn r ->
          r.single_agent.status == :pass or r.multi_agent.status == :pass
        end)

      assert total_completions >= 4,
             "Expected at least half the tasks to complete with one strategy"
    end
  end

  # Helper: Run task with specific strategy
  defp run_task_with_strategy(tmp_dir, task_spec, strategy) do
    repo_dir = setup_repo(tmp_dir, task_spec, strategy)
    issue_id = write_issue(repo_dir, task_spec)

    start_time = System.monotonic_time(:second)

    # Run deft work with strategy configured via config file
    result = run_deft_with_strategy(repo_dir, issue_id, strategy, @cost_ceiling_default)

    end_time = System.monotonic_time(:second)
    duration = end_time - start_time

    %{
      status: result.status,
      cost: result.cost,
      time: duration
    }
  end

  # Helper: Run synthetic task
  defp run_synthetic_task(tmp_dir, task, strategy) do
    # Create repo for the specific task
    repo_dir = Path.join(tmp_dir, "#{task.name}_#{strategy}")
    File.mkdir_p!(repo_dir)

    # Initialize git
    System.cmd("git", ["init"], cd: repo_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    # Create basic structure
    File.mkdir_p!(Path.join(repo_dir, "lib"))
    File.mkdir_p!(Path.join(repo_dir, "test"))
    File.mkdir_p!(Path.join(repo_dir, ".deft"))

    # Write minimal mix.exs
    mix_content = """
    defmodule TestProject.MixProject do
      use Mix.Project
      def project, do: [app: :test_project, version: "0.1.0", elixir: "~> 1.14"]
      def application, do: [extra_applications: [:logger]]
    end
    """

    File.write!(Path.join(repo_dir, "mix.exs"), mix_content)

    # Write strategy-specific config
    write_strategy_config(repo_dir, strategy)

    # Initial commit
    System.cmd("git", ["add", "."], cd: repo_dir)
    System.cmd("git", ["commit", "-m", "Initial"], cd: repo_dir)

    # Write issue for this task
    issue_id = "task_#{task.name}_#{:erlang.unique_integer([:positive])}"
    task_spec = build_task_spec(task)
    write_issue(repo_dir, Map.put(task_spec, :title, issue_id))

    # Run deft work and measure time
    start_time = System.monotonic_time(:second)
    result = run_deft_work(repo_dir, issue_id, @cost_ceiling_default)
    end_time = System.monotonic_time(:second)

    %{
      status: result.status,
      cost: result.cost,
      time: end_time - start_time
    }
  end

  # Helper: Setup repo for task
  defp setup_repo(tmp_dir, task_spec, strategy) do
    repo_name = "#{task_spec.title}_#{strategy}"
    repo_dir = Path.join(tmp_dir, String.replace(repo_name, " ", "_"))

    File.mkdir_p!(repo_dir)

    # Initialize git
    System.cmd("git", ["init"], cd: repo_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    # Create basic structure
    File.mkdir_p!(Path.join(repo_dir, "lib"))
    File.mkdir_p!(Path.join(repo_dir, "test"))
    File.mkdir_p!(Path.join(repo_dir, ".deft"))

    # Write minimal mix.exs
    mix_content = """
    defmodule TestProject.MixProject do
      use Mix.Project
      def project, do: [app: :test_project, version: "0.1.0", elixir: "~> 1.14"]
      def application, do: [extra_applications: [:logger]]
    end
    """

    File.write!(Path.join(repo_dir, "mix.exs"), mix_content)

    # Write strategy-specific config
    write_strategy_config(repo_dir, strategy)

    # Initial commit
    System.cmd("git", ["add", "."], cd: repo_dir)
    System.cmd("git", ["commit", "-m", "Initial"], cd: repo_dir)

    repo_dir
  end

  # Helper: Write issue
  defp write_issue(repo_dir, task_spec) do
    issue_id = Map.get(task_spec, :id, "multi_#{:erlang.unique_integer([:positive])}")
    issues_file = Path.join([repo_dir, ".deft", "issues.jsonl"])

    issue = %{
      id: issue_id,
      title: task_spec.title,
      description: task_spec.description,
      acceptance_criteria: task_spec.acceptance_criteria,
      status: "open",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(issues_file, Jason.encode!(issue) <> "\n")
    issue_id
  end

  # Helper: Run deft with specific strategy via config
  defp run_deft_with_strategy(repo_dir, issue_id, _strategy, _cost_ceiling) do
    # Strategy is already configured via write_strategy_config in setup_repo
    run_deft_work(repo_dir, issue_id, @cost_ceiling_default)
  end

  # Helper: Write config to control single vs multi-agent mode
  defp write_strategy_config(repo_dir, strategy) do
    config_dir = Path.join(repo_dir, ".deft")
    File.mkdir_p!(config_dir)
    config_file = Path.join(config_dir, "config.yaml")

    config_content =
      case strategy do
        :single_agent ->
          # Force single-agent by preventing Lead spawning
          """
          job_max_leads: 0
          """

        :multi_agent ->
          # Allow multi-agent orchestration (default behavior)
          """
          job_max_leads: 5
          """
      end

    File.write!(config_file, config_content)
  end

  # Helper: Build task spec from task map
  defp build_task_spec(task) do
    case task.name do
      "fix_test" ->
        %{
          title: "Fix failing test",
          description: "Fix the failing test in math module",
          acceptance_criteria: ["All tests pass"],
          complexity: :low
        }

      "add_schema" ->
        %{
          title: "Add schema field",
          description: "Add a new field to the User schema with migration",
          acceptance_criteria: ["Migration exists", "Schema compiles"],
          complexity: :low
        }

      "add_controller" ->
        %{
          title: "Add controller action",
          description: "Add GET /api/users/:id endpoint with tests",
          acceptance_criteria: [
            "New action exists",
            "Integration test passes",
            "Route registered"
          ],
          complexity: :medium
        }

      "refactor" ->
        %{
          title: "Refactor module",
          description: "Refactor the Parser module without breaking tests",
          acceptance_criteria: ["Tests pass", "Structure changed"],
          complexity: :medium
        }

      "fix_bug" ->
        %{
          title: "Fix bug",
          description: "Fix the bug where users can't login with email",
          acceptance_criteria: ["Bug fixed", "Test added"],
          complexity: :medium
        }

      "genserver" ->
        %{
          title: "Implement GenServer",
          description: "Implement a cache GenServer per spec",
          acceptance_criteria: ["GenServer compiles", "Tests pass"],
          complexity: :medium
        }

      "cross_file" ->
        %{
          title: "Update behavior and implementors",
          description: "Add required callback to Storage behavior and update all implementors",
          acceptance_criteria: [
            "Behavior updated",
            "All implementations compile",
            "All tests pass"
          ],
          complexity: :high
        }

      "constrained" ->
        %{
          title: "Add feature with constraint",
          description: "Add user deletion feature without changing public API",
          acceptance_criteria: ["Feature works", "Public API unchanged"],
          complexity: :high
        }
    end
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
        %{status: :pass, cost: cost}

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
end
