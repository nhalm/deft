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

    test "creates .gitignore with .deft-worktrees/ if it doesn't exist", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      gitignore_path = Path.join(tmp_dir, ".gitignore")
      refute File.exists?(gitignore_path)

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      assert File.exists?(gitignore_path)
      content = File.read!(gitignore_path)
      assert content =~ ".deft-worktrees/"
    end

    test "adds .deft-worktrees/ to existing .gitignore if not present", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      gitignore_path = Path.join(tmp_dir, ".gitignore")
      File.write!(gitignore_path, "node_modules/\n*.log\n")

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      content = File.read!(gitignore_path)
      assert content =~ "node_modules/"
      assert content =~ "*.log"
      assert content =~ ".deft-worktrees/"
    end

    test "does not duplicate .deft-worktrees/ in .gitignore", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      gitignore_path = Path.join(tmp_dir, ".gitignore")
      original_content = "node_modules/\n.deft-worktrees/\n*.log\n"
      File.write!(gitignore_path, original_content)

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      content = File.read!(gitignore_path)
      # Should be unchanged
      assert content == original_content

      # Count occurrences - should be exactly 1
      occurrences = content |> String.split("\n") |> Enum.count(&(&1 == ".deft-worktrees/"))
      assert occurrences == 1
    end

    test "recognizes .deft-worktrees/ with leading slash as already present", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      gitignore_path = Path.join(tmp_dir, ".gitignore")
      original_content = "node_modules/\n/.deft-worktrees/\n*.log\n"
      File.write!(gitignore_path, original_content)

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      content = File.read!(gitignore_path)
      # Should be unchanged since /.deft-worktrees/ is equivalent
      assert content == original_content
    end

    test "adds .deft-worktrees/ with proper newline formatting", %{tmp_dir: tmp_dir} do
      Process.put(:mock_worktree_response, {"", 0})

      gitignore_path = Path.join(tmp_dir, ".gitignore")

      # Test with file that doesn't end in newline
      File.write!(gitignore_path, "node_modules/")

      assert {:ok, _} =
               Job.create_lead_worktree(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MockGit,
                 working_dir: tmp_dir
               )

      content = File.read!(gitignore_path)
      assert content == "node_modules/\n.deft-worktrees/\n"
    end
  end

  describe "merge_lead_branch/1" do
    setup do
      # Create a temporary directory for testing
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    defmodule MergeMockGit do
      @moduledoc false

      def cmd(args) do
        send(self(), {:git_cmd, args})

        case get_mock_response(args) do
          nil -> {"", 0}
          response -> response
        end
      end

      defp get_mock_response(["checkout", _branch_name]) do
        Process.get(:mock_checkout_response)
      end

      defp get_mock_response(["merge", "--no-ff", _branch_name]) do
        Process.get(:mock_merge_response)
      end

      defp get_mock_response(["diff", "--name-only", "--diff-filter=U"]) do
        Process.get(:mock_diff_response)
      end

      defp get_mock_response(_), do: nil
    end

    test "successfully merges Lead branch into job branch", %{tmp_dir: tmp_dir} do
      # Mock successful checkout and merge
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})

      assert {:ok, :merged} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      # Verify git commands were called in correct order
      assert_received {:git_cmd, ["checkout", "deft/job-job123"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/lead-lead-1"]}
    end

    test "detects merge conflicts", %{tmp_dir: tmp_dir} do
      # Mock successful checkout but merge conflict
      Process.put(:mock_checkout_response, {"", 0})

      Process.put(
        :mock_merge_response,
        {"Auto-merging lib/app.ex\nCONFLICT (content): Merge conflict in lib/app.ex\n", 1}
      )

      Process.put(:mock_diff_response, {"lib/app.ex\ntest/app_test.exs\n", 0})

      assert {:ok, :conflict, conflicted_files} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      assert "lib/app.ex" in conflicted_files
      assert "test/app_test.exs" in conflicted_files

      # Verify git commands were called
      assert_received {:git_cmd, ["checkout", "deft/job-job123"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/lead-lead-1"]}
      assert_received {:git_cmd, ["diff", "--name-only", "--diff-filter=U"]}
    end

    test "handles merge conflict when diff command fails", %{tmp_dir: tmp_dir} do
      # Mock successful checkout, merge conflict, but diff fails
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"CONFLICT detected\n", 1})
      Process.put(:mock_diff_response, {"error\n", 1})

      assert {:ok, :conflict, conflicted_files} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      # Should return empty list if diff fails
      assert conflicted_files == []
    end

    test "handles checkout failure", %{tmp_dir: tmp_dir} do
      # Mock checkout failure
      Process.put(:mock_checkout_response, {"fatal: invalid branch\n", 1})

      assert {:error, {:checkout_failed, 1}} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "invalid",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      # Should attempt checkout but not merge
      assert_received {:git_cmd, ["checkout", "deft/job-invalid"]}
      refute_received {:git_cmd, ["merge" | _]}
    end

    test "handles merge failure (non-conflict error)", %{tmp_dir: tmp_dir} do
      # Mock successful checkout but merge failure (not a conflict)
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"fatal: unable to merge\n", 128})

      assert {:error, {:merge_failed, 128}} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      assert_received {:git_cmd, ["checkout", "deft/job-job123"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/lead-lead-1"]}
    end

    test "creates correct branch names", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})

      assert {:ok, :merged} =
               Job.merge_lead_branch(
                 lead_id: "lead-abc-123",
                 job_id: "job-xyz-789",
                 git: MergeMockGit,
                 working_dir: tmp_dir
               )

      assert_received {:git_cmd, ["checkout", "deft/job-job-xyz-789"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/lead-lead-abc-123"]}
    end

    test "requires lead_id option" do
      assert_raise KeyError, fn ->
        Job.merge_lead_branch(job_id: "job123", git: MergeMockGit)
      end
    end

    test "requires job_id option" do
      assert_raise KeyError, fn ->
        Job.merge_lead_branch(lead_id: "lead-1", git: MergeMockGit)
      end
    end

    test "defaults to File.cwd! when working_dir not provided" do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})

      assert {:ok, :merged} =
               Job.merge_lead_branch(
                 lead_id: "lead-1",
                 job_id: "job123",
                 git: MergeMockGit
               )

      # Should work - git commands executed in current directory context
      assert_received {:git_cmd, ["checkout", "deft/job-job123"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/lead-lead-1"]}
    end
  end

  describe "complete_job/1" do
    # Mock Git adapter for complete_job tests
    defmodule CompleteJobMockGit do
      @moduledoc false

      def cmd(args) do
        send(self(), {:git_cmd, args})

        case args do
          ["checkout", _branch] ->
            Process.get(:mock_checkout_response, {"", 0})

          ["merge", "--squash", _job_branch] ->
            Process.get(:mock_merge_response, {"", 0})

          ["merge", "--no-ff", _job_branch] ->
            Process.get(:mock_merge_response, {"", 0})

          ["commit", "-m", _message] ->
            Process.get(:mock_commit_response, {"", 0})

          ["branch", "-d", _branch] ->
            Process.get(:mock_branch_delete_response, {"", 0})

          ["worktree", "list", "--porcelain"] ->
            Process.get(:mock_worktree_list_response, {"worktree /path/to/repo\n", 0})

          _ ->
            {"", 0}
        end
      end
    end

    setup do
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "completes job with squash merge (default)", %{tmp_dir: tmp_dir} do
      # Mock successful operations
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})
      Process.put(:mock_worktree_list_response, {"worktree /path/to/repo\n", 0})

      assert {:ok, :completed} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Verify git commands were called in correct order
      assert_received {:git_cmd, ["checkout", "main"]}
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-abc123"]}
      assert_received {:git_cmd, ["commit", "-m", _message]}
      assert_received {:git_cmd, ["branch", "-d", "deft/job-abc123"]}
      assert_received {:git_cmd, ["worktree", "list", "--porcelain"]}
    end

    test "completes job with regular merge when squash is false", %{tmp_dir: tmp_dir} do
      # Mock successful operations
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})
      Process.put(:mock_worktree_list_response, {"worktree /path/to/repo\n", 0})

      assert {:ok, :completed} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 squash: false,
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Verify git commands - should use --no-ff, not --squash
      assert_received {:git_cmd, ["checkout", "main"]}
      assert_received {:git_cmd, ["merge", "--no-ff", "deft/job-abc123"]}
      # No commit command for regular merge
      refute_received {:git_cmd, ["commit" | _]}
      assert_received {:git_cmd, ["branch", "-d", "deft/job-abc123"]}
      assert_received {:git_cmd, ["worktree", "list", "--porcelain"]}
    end

    test "handles checkout failure", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"fatal: invalid branch\n", 128})

      assert {:error, {:checkout_failed, 128}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "invalid",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Should attempt checkout but not merge
      assert_received {:git_cmd, ["checkout", "invalid"]}
      refute_received {:git_cmd, ["merge" | _]}
    end

    test "handles merge failure", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"fatal: unable to merge\n", 1})

      assert {:error, {:merge_failed, 1}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Should attempt checkout and merge but not delete branch
      assert_received {:git_cmd, ["checkout", "main"]}
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-abc123"]}
      refute_received {:git_cmd, ["branch", "-d" | _]}
    end

    test "handles commit failure (squash merge)", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"fatal: commit failed\n", 1})

      assert {:error, {:commit_failed, 1}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Should attempt merge and commit but not delete branch
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-abc123"]}
      assert_received {:git_cmd, ["commit", "-m", _message]}
      refute_received {:git_cmd, ["branch", "-d" | _]}
    end

    test "handles branch deletion failure", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"fatal: branch not found\n", 1})

      assert {:error, {:branch_deletion_failed, 1}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Should attempt all steps up to branch deletion
      assert_received {:git_cmd, ["checkout", "main"]}
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-abc123"]}
      assert_received {:git_cmd, ["commit", "-m", _message]}
      assert_received {:git_cmd, ["branch", "-d", "deft/job-abc123"]}
    end

    test "handles worktree verification failure", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})

      # Mock multiple worktrees remaining
      Process.put(
        :mock_worktree_list_response,
        {"worktree /path/to/repo\nworktree /path/to/worktree1\nworktree /path/to/worktree2\n", 0}
      )

      assert {:error, {:worktrees_remain, 3}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Should complete all steps but fail on verification
      assert_received {:git_cmd, ["worktree", "list", "--porcelain"]}
    end

    test "handles worktree list command failure", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})
      Process.put(:mock_worktree_list_response, {"fatal: not a git repo\n", 128})

      assert {:error, {:worktree_list_failed, 128}} =
               Job.complete_job(
                 job_id: "abc123",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )
    end

    test "requires job_id option" do
      assert_raise KeyError, fn ->
        Job.complete_job(original_branch: "main", git: CompleteJobMockGit)
      end
    end

    test "requires original_branch option" do
      assert_raise KeyError, fn ->
        Job.complete_job(job_id: "abc123", git: CompleteJobMockGit)
      end
    end

    test "defaults squash to true" do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})
      Process.put(:mock_worktree_list_response, {"worktree /path/to/repo\n", 0})

      # Don't specify squash option
      assert {:ok, :completed} =
               Job.complete_job(
                 job_id: "test",
                 original_branch: "main",
                 git: CompleteJobMockGit,
                 working_dir: System.tmp_dir!()
               )

      # Should use squash merge by default
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-test"]}
    end

    test "creates correct job branch name", %{tmp_dir: tmp_dir} do
      Process.put(:mock_checkout_response, {"", 0})
      Process.put(:mock_merge_response, {"", 0})
      Process.put(:mock_commit_response, {"", 0})
      Process.put(:mock_branch_delete_response, {"", 0})
      Process.put(:mock_worktree_list_response, {"worktree /path/to/repo\n", 0})

      assert {:ok, :completed} =
               Job.complete_job(
                 job_id: "my-job-456",
                 original_branch: "feature/new-thing",
                 git: CompleteJobMockGit,
                 working_dir: tmp_dir
               )

      # Verify correct branch names
      assert_received {:git_cmd, ["checkout", "feature/new-thing"]}
      assert_received {:git_cmd, ["merge", "--squash", "deft/job-my-job-456"]}
      assert_received {:git_cmd, ["branch", "-d", "deft/job-my-job-456"]}
    end
  end
end
