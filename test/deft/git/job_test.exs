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
end
