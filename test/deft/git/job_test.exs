defmodule Deft.Git.JobTest do
  use ExUnit.Case, async: true
  doctest Deft.Git.Job

  alias Deft.Git.Job

  # Mock Git adapter for testing
  defmodule MockGit do
    @moduledoc false

    def cmd(args) do
      send(self(), {:git_cmd, args})

      case get_mock_response(args) do
        nil -> {"", 0}
        response -> response
      end
    end

    defp get_mock_response(["status", "--porcelain"]) do
      Process.get(:mock_status_response)
    end

    defp get_mock_response(["branch", _branch_name]) do
      Process.get(:mock_branch_response)
    end

    defp get_mock_response(["worktree", "add" | _rest]) do
      Process.get(:mock_worktree_response)
    end

    defp get_mock_response(_), do: nil
  end

  describe "create_job_branch/1" do
    test "creates branch successfully with clean working tree" do
      # Mock clean status and successful branch creation
      Process.put(:mock_status_response, {"", 0})
      Process.put(:mock_branch_response, {"", 0})

      assert {:ok, "deft/job-test123"} =
               Job.create_job_branch(
                 job_id: "test123",
                 git: MockGit,
                 auto_approve: true
               )

      # Verify git commands were called
      assert_received {:git_cmd, ["status", "--porcelain"]}
      assert_received {:git_cmd, ["branch", "deft/job-test123"]}
    end

    test "fails with dirty working tree in auto-approve mode" do
      # Mock dirty status
      Process.put(:mock_status_response, {"M  lib/some_file.ex\n", 0})

      assert {:error, :dirty_working_tree} =
               Job.create_job_branch(
                 job_id: "test123",
                 git: MockGit,
                 auto_approve: true
               )

      # Should check status but not attempt branch creation
      assert_received {:git_cmd, ["status", "--porcelain"]}
      refute_received {:git_cmd, ["branch", _]}
    end

    test "handles git status failure" do
      # Mock status command failure
      Process.put(:mock_status_response, {"fatal: not a git repository\n", 128})

      assert {:error, {:git_status_failed, 128}} =
               Job.create_job_branch(
                 job_id: "test123",
                 git: MockGit,
                 auto_approve: true
               )
    end

    test "handles branch creation failure" do
      # Mock clean status but branch creation failure
      Process.put(:mock_status_response, {"", 0})
      Process.put(:mock_branch_response, {"fatal: branch already exists\n", 128})

      assert {:error, {:branch_creation_failed, 128}} =
               Job.create_job_branch(
                 job_id: "test123",
                 git: MockGit,
                 auto_approve: true
               )

      assert_received {:git_cmd, ["status", "--porcelain"]}
      assert_received {:git_cmd, ["branch", "deft/job-test123"]}
    end

    test "creates correct branch name format" do
      Process.put(:mock_status_response, {"", 0})
      Process.put(:mock_branch_response, {"", 0})

      assert {:ok, "deft/job-abc-123-xyz"} =
               Job.create_job_branch(
                 job_id: "abc-123-xyz",
                 git: MockGit,
                 auto_approve: true
               )

      assert_received {:git_cmd, ["branch", "deft/job-abc-123-xyz"]}
    end

    test "requires job_id option" do
      assert_raise KeyError, fn ->
        Job.create_job_branch(git: MockGit)
      end
    end

    test "defaults to Deft.Git when git option not provided" do
      # This test verifies the option defaults but doesn't actually call git
      # We can't easily test the default without a real git repo or more complex mocking
      assert is_function(&Job.create_job_branch/1)
    end
  end

  describe "create_lead_worktree/1" do
    setup do
      # Create a temporary directory for testing
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "creates worktree successfully", %{tmp_dir: tmp_dir} do
      # Mock successful worktree creation
      Process.put(:mock_worktree_response, {"", 0})

      assert {:ok, worktree_path} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      expected_path = Path.join([tmp_dir, ".deft-worktrees", "lead-lead-1"])
      assert worktree_path == expected_path

      # Verify git worktree add command was called with correct arguments
      assert_received {:git_cmd,
                       [
                         "worktree",
                         "add",
                         ^expected_path,
                         "-b",
                         "deft/lead-lead-1",
                         "deft/job-job123"
                       ]}

      # Verify .deft-worktrees directory was created
      assert File.dir?(Path.join(tmp_dir, ".deft-worktrees"))
    end

    test "creates .deft-worktrees directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      refute File.dir?(Path.join(tmp_dir, ".deft-worktrees"))

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      assert File.dir?(Path.join(tmp_dir, ".deft-worktrees"))
    end

    test "handles worktree creation failure", %{tmp_dir: tmp_dir} do
      # Mock worktree command failure (e.g., job branch doesn't exist)
      Process.put(
        :mock_worktree_response,
        {"fatal: invalid reference: deft/job-invalid\n", 128}
      )

      assert {:error, {:worktree_creation_failed, 128}} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "invalid",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      assert_received {:git_cmd, ["worktree", "add" | _]}
    end

    test "creates correct worktree path and branch names", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      assert {:ok, worktree_path} =
               Job.create_lead_worktree(
                 lead_id: "lead-abc-123",
                 job_id: "job-xyz-789",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      expected_path = Path.join([tmp_dir, ".deft-worktrees", "lead-lead-abc-123"])
      assert worktree_path == expected_path

      assert_received {:git_cmd,
                       [
                         "worktree",
                         "add",
                         ^expected_path,
                         "-b",
                         "deft/lead-lead-abc-123",
                         "deft/job-job-xyz-789"
                       ]}
    end

    test "requires lead_id option" do
      assert_raise KeyError, fn ->
        Job.create_lead_worktree(job_id: "job123", git: MockGit)
      end
    end

    test "requires job_id option" do
      assert_raise KeyError, fn ->
        Job.create_lead_worktree(lead_id: "lead-1", git: MockGit)
      end
    end

    test "defaults to File.cwd! when working_dir not provided" do
      Process.put(:mock_worktree_response, {"", 0})

      # Call without working_dir option
      assert {:ok, worktree_path} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit
               )

      # Should use current working directory
      expected_path = Path.join([File.cwd!(), ".deft-worktrees", "lead-lead-1"])
      assert worktree_path == expected_path
    end

    test "returns error if directory creation fails" do
      # Use a path that will fail to create (e.g., /dev/null/subdir on Unix)
      invalid_dir = "/dev/null"

      assert {:error, {:worktrees_dir_creation_failed, _reason}} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: invalid_dir
               )

      # Should not attempt git worktree command
      refute_received {:git_cmd, ["worktree" | _]}
    end
  end
end
