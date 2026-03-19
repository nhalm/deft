defmodule Deft.IssuesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deft.Issues

  setup do
    # Use a temporary directory for test files
    tmp_dir =
      System.tmp_dir!() |> Path.join("deft-issues-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    file_path = Path.join([tmp_dir, ".deft", "issues.jsonl"])

    on_exit(fn ->
      case Process.whereis(Issues) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          try do
            GenServer.stop(Issues, :normal)
          catch
            :exit, _ -> :ok
          end
      end

      File.rm_rf!(tmp_dir)
    end)

    %{file_path: file_path, tmp_dir: tmp_dir}
  end

  describe "cycle detection on load" do
    test "detects simple two-issue cycle and clears dependencies", %{file_path: file_path} do
      # Create two issues with circular dependency
      issue1 = %{
        id: "deft-aaa1",
        title: "Issue 1",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-bbb2"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      issue2 = %{
        id: "deft-bbb2",
        title: "Issue 2",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-aaa1"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      # Write issues to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line1 = Jason.encode!(issue1) <> "\n"
      line2 = Jason.encode!(issue2) <> "\n"
      File.write!(file_path, line1 <> line2)

      # Start Issues GenServer and capture log output
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path)
        end)

      # Verify warnings were logged for both issues
      assert log =~ "Issue deft-aaa1 is part of a dependency cycle"
      assert log =~ "Issue deft-bbb2 is part of a dependency cycle"

      # Verify dependencies were cleared
      {:ok, loaded_issue1} = Issues.get("deft-aaa1")
      {:ok, loaded_issue2} = Issues.get("deft-bbb2")

      assert loaded_issue1.dependencies == []
      assert loaded_issue2.dependencies == []
    end

    test "detects three-issue cycle and clears dependencies", %{file_path: file_path} do
      # Create three issues with circular dependency: A -> B -> C -> A
      issue_a = %{
        id: "deft-aaa3",
        title: "Issue A",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-bbb4"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      issue_b = %{
        id: "deft-bbb4",
        title: "Issue B",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-ccc5"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      issue_c = %{
        id: "deft-ccc5",
        title: "Issue C",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-aaa3"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      # Write issues to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line_a = Jason.encode!(issue_a) <> "\n"
      line_b = Jason.encode!(issue_b) <> "\n"
      line_c = Jason.encode!(issue_c) <> "\n"
      File.write!(file_path, line_a <> line_b <> line_c)

      # Start Issues GenServer and capture log output
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path)
        end)

      # Verify warnings were logged for all three issues
      assert log =~ "Issue deft-aaa3 is part of a dependency cycle"
      assert log =~ "Issue deft-bbb4 is part of a dependency cycle"
      assert log =~ "Issue deft-ccc5 is part of a dependency cycle"

      # Verify dependencies were cleared
      {:ok, loaded_issue_a} = Issues.get("deft-aaa3")
      {:ok, loaded_issue_b} = Issues.get("deft-bbb4")
      {:ok, loaded_issue_c} = Issues.get("deft-ccc5")

      assert loaded_issue_a.dependencies == []
      assert loaded_issue_b.dependencies == []
      assert loaded_issue_c.dependencies == []
    end

    test "does not clear dependencies when no cycle exists", %{file_path: file_path} do
      # Create three issues with valid dependency chain: A -> B -> C
      issue_a = %{
        id: "deft-aaa6",
        title: "Issue A",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-bbb7"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      issue_b = %{
        id: "deft-bbb7",
        title: "Issue B",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-ccc8"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      issue_c = %{
        id: "deft-ccc8",
        title: "Issue C",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: [],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      # Write issues to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line_a = Jason.encode!(issue_a) <> "\n"
      line_b = Jason.encode!(issue_b) <> "\n"
      line_c = Jason.encode!(issue_c) <> "\n"
      File.write!(file_path, line_a <> line_b <> line_c)

      # Start Issues GenServer
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path)
        end)

      # Verify no cycle warnings were logged
      refute log =~ "Cycle detected"

      # Verify dependencies remain intact
      {:ok, loaded_issue_a} = Issues.get("deft-aaa6")
      {:ok, loaded_issue_b} = Issues.get("deft-bbb7")
      {:ok, loaded_issue_c} = Issues.get("deft-ccc8")

      assert loaded_issue_a.dependencies == ["deft-bbb7"]
      assert loaded_issue_b.dependencies == ["deft-ccc8"]
      assert loaded_issue_c.dependencies == []
    end

    test "handles self-referential cycle", %{file_path: file_path} do
      # Create issue that depends on itself
      issue = %{
        id: "deft-self",
        title: "Self Issue",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: ["deft-self"],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      # Write issue to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line = Jason.encode!(issue) <> "\n"
      File.write!(file_path, line)

      # Start Issues GenServer and capture log output
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path)
        end)

      # Verify warning was logged
      assert log =~ "Issue deft-self is part of a dependency cycle"

      # Verify dependency was cleared
      {:ok, loaded_issue} = Issues.get("deft-self")
      assert loaded_issue.dependencies == []
    end

    test "rejects issue creation with non-existent blocker", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Try to create an issue with a non-existent blocker
      result =
        Issues.create(%{
          title: "Issue with bad blocker",
          source: :user,
          dependencies: ["deft-nonexistent"]
        })

      assert {:error, {:blocker_not_found, "deft-nonexistent"}} = result
    end

    test "rejects issue creation with multiple non-existent blockers", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create one valid issue
      {:ok, valid_issue} = Issues.create(%{title: "Valid Issue", source: :user})

      # Try to create an issue with one valid and two invalid blockers
      result =
        Issues.create(%{
          title: "Issue with bad blockers",
          source: :user,
          dependencies: [valid_issue.id, "deft-bad1", "deft-bad2"]
        })

      assert {:error, {:blockers_not_found, ["deft-bad1", "deft-bad2"]}} = result
    end

    test "allows issue creation with all valid blockers", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create two issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})

      # Create an issue that depends on both
      result =
        Issues.create(%{
          title: "Issue 3",
          source: :user,
          dependencies: [issue1.id, issue2.id]
        })

      assert {:ok, issue3} = result
      assert issue3.dependencies == [issue1.id, issue2.id]
    end
  end

  describe "closed issue compaction" do
    test "compacts closed issues older than compaction_days threshold", %{file_path: file_path} do
      # Create issues with different dates
      # Old closed issue (100 days ago)
      old_closed_date =
        DateTime.utc_now()
        |> DateTime.add(-100, :day)
        |> DateTime.to_iso8601()

      old_closed_issue = %{
        id: "deft-old1",
        title: "Old Closed Issue",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "closed",
        priority: 2,
        dependencies: [],
        created_at: old_closed_date,
        updated_at: old_closed_date,
        closed_at: old_closed_date,
        source: "user",
        job_id: "job-123"
      }

      # Recent closed issue (30 days ago) - should NOT be compacted
      recent_closed_date =
        DateTime.utc_now()
        |> DateTime.add(-30, :day)
        |> DateTime.to_iso8601()

      recent_closed_issue = %{
        id: "deft-recent2",
        title: "Recent Closed Issue",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "closed",
        priority: 2,
        dependencies: [],
        created_at: recent_closed_date,
        updated_at: recent_closed_date,
        closed_at: recent_closed_date,
        source: "user",
        job_id: "job-456"
      }

      # Open issue - should NOT be compacted
      open_issue = %{
        id: "deft-open3",
        title: "Open Issue",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "open",
        priority: 2,
        dependencies: [],
        created_at: "2026-03-17T10:00:00Z",
        updated_at: "2026-03-17T10:00:00Z",
        closed_at: nil,
        source: "user",
        job_id: nil
      }

      # Write issues to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line1 = Jason.encode!(old_closed_issue) <> "\n"
      line2 = Jason.encode!(recent_closed_issue) <> "\n"
      line3 = Jason.encode!(open_issue) <> "\n"
      File.write!(file_path, line1 <> line2 <> line3)

      # Start Issues GenServer with 90-day compaction threshold
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path, compaction_days: 90)
        end)

      # Verify compaction log message
      assert log =~ "Compacted 1 closed issues older than 90 days"

      # Verify old closed issue was compacted (not found)
      assert {:error, :not_found} = Issues.get("deft-old1")

      # Verify recent closed issue was kept
      assert {:ok, _} = Issues.get("deft-recent2")

      # Verify open issue was kept
      assert {:ok, _} = Issues.get("deft-open3")
    end

    test "does not compact when all closed issues are recent", %{file_path: file_path} do
      # Recent closed issue (30 days ago)
      recent_closed_date =
        DateTime.utc_now()
        |> DateTime.add(-30, :day)
        |> DateTime.to_iso8601()

      recent_closed_issue = %{
        id: "deft-recent4",
        title: "Recent Closed Issue",
        context: "",
        acceptance_criteria: [],
        constraints: [],
        status: "closed",
        priority: 2,
        dependencies: [],
        created_at: recent_closed_date,
        updated_at: recent_closed_date,
        closed_at: recent_closed_date,
        source: "user",
        job_id: "job-789"
      }

      # Write issue to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      line = Jason.encode!(recent_closed_issue) <> "\n"
      File.write!(file_path, line)

      # Start Issues GenServer
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path, compaction_days: 90)
        end)

      # Verify no compaction message
      refute log =~ "Compacted"

      # Verify issue was kept
      assert {:ok, _} = Issues.get("deft-recent4")
    end

    test "compacts multiple old closed issues", %{file_path: file_path} do
      # Create three old closed issues (100 days ago)
      old_closed_date =
        DateTime.utc_now()
        |> DateTime.add(-100, :day)
        |> DateTime.to_iso8601()

      old_issues =
        for i <- 1..3 do
          %{
            id: "deft-old#{i}",
            title: "Old Closed Issue #{i}",
            context: "",
            acceptance_criteria: [],
            constraints: [],
            status: "closed",
            priority: 2,
            dependencies: [],
            created_at: old_closed_date,
            updated_at: old_closed_date,
            closed_at: old_closed_date,
            source: "user",
            job_id: "job-#{i}"
          }
        end

      # Write issues to JSONL file
      File.mkdir_p!(Path.dirname(file_path))
      lines = Enum.map(old_issues, fn issue -> Jason.encode!(issue) <> "\n" end)
      File.write!(file_path, Enum.join(lines))

      # Start Issues GenServer
      log =
        capture_log(fn ->
          {:ok, _pid} = Issues.start_link(file_path: file_path, compaction_days: 90)
        end)

      # Verify compaction log message
      assert log =~ "Compacted 3 closed issues older than 90 days"

      # Verify all old issues were compacted
      assert {:error, :not_found} = Issues.get("deft-old1")
      assert {:error, :not_found} = Issues.get("deft-old2")
      assert {:error, :not_found} = Issues.get("deft-old3")
    end
  end

  describe "worktree awareness" do
    setup do
      # Save and restore git adapter and mock response config for each test
      original_adapter = Application.get_env(:deft, :git_adapter)
      original_mock_response = Application.get_env(:deft, :git_mock_response)

      on_exit(fn ->
        if original_adapter do
          Application.put_env(:deft, :git_adapter, original_adapter)
        else
          Application.delete_env(:deft, :git_adapter)
        end

        if original_mock_response do
          Application.put_env(:deft, :git_mock_response, original_mock_response)
        else
          Application.delete_env(:deft, :git_mock_response)
        end
      end)

      :ok
    end

    test "resolves to main repo path when in a worktree", %{tmp_dir: tmp_dir} do
      # Set up main repo structure
      main_repo = Path.join(tmp_dir, "main-repo")
      git_dir = Path.join(main_repo, ".git")
      worktrees_dir = Path.join([git_dir, "worktrees", "lead-123"])
      File.mkdir_p!(worktrees_dir)

      # Create .deft directory in main repo
      deft_dir = Path.join(main_repo, ".deft")
      File.mkdir_p!(deft_dir)
      main_issues_file = Path.join(deft_dir, "issues.jsonl")

      # Configure mock to simulate worktree
      # git rev-parse --git-common-dir returns the common git dir
      common_dir = git_dir
      Application.put_env(:deft, :git_mock_response, {"#{common_dir}\n", 0})

      # Configure git adapter to use mock BEFORE starting GenServer
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Start Issues without explicit file_path to trigger resolve_file_path
      {:ok, _pid} = Issues.start_link()

      # Create an issue to trigger file creation
      {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

      # Verify the file was created in the main repo, not the worktree
      assert File.exists?(main_issues_file)
    end

    test "uses cwd when not in a git repository", %{tmp_dir: tmp_dir} do
      # Configure mock to simulate not being in a git repo
      # Mock will simulate that git command fails
      Application.put_env(:deft, :git_mock_response, {"fatal: not a git repository\n", 128})

      # Configure git adapter to use mock BEFORE starting GenServer
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Change to tmp_dir so File.cwd!() returns it
      # Note: File.cd affects the entire VM, so this test cannot run async
      original_cwd = File.cwd!()

      try do
        File.cd!(tmp_dir)

        # Start Issues without explicit file_path to trigger automatic resolution
        {:ok, _pid} = Issues.start_link()

        # Create an issue to trigger file creation
        {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

        # Verify the file was created in tmp_dir/.deft/
        expected_file = Path.join([tmp_dir, ".deft", "issues.jsonl"])
        assert File.exists?(expected_file)

        # Verify .deft directory was created
        assert File.dir?(Path.join(tmp_dir, ".deft"))
      after
        # Restore original working directory
        File.cd!(original_cwd)
      end
    end

    test "resolves correctly when .git is a regular directory (not worktree)", %{tmp_dir: tmp_dir} do
      # Set up regular repo structure
      repo = Path.join(tmp_dir, "regular-repo")
      git_dir = Path.join(repo, ".git")
      File.mkdir_p!(git_dir)

      # Configure mock to simulate regular repo
      # In a regular repo, git rev-parse --git-common-dir returns .git
      Application.put_env(:deft, :git_mock_response, {"#{git_dir}\n", 0})

      # Configure git adapter to use mock BEFORE starting GenServer
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Start Issues without explicit file_path
      {:ok, _pid} = Issues.start_link()

      # Create an issue to trigger file creation
      {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

      # Verify the file was created in repo/.deft/
      expected_file = Path.join([repo, ".deft", "issues.jsonl"])
      assert File.exists?(expected_file)
    end
  end

  describe "add_dependency/2" do
    test "adds a dependency to an issue", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create two issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})

      # Add issue2 as a dependency of issue1
      {:ok, updated_issue} = Issues.add_dependency(issue1.id, issue2.id)

      assert updated_issue.dependencies == [issue2.id]
      assert updated_issue.id == issue1.id

      # Verify the dependency was persisted
      {:ok, loaded_issue} = Issues.get(issue1.id)
      assert loaded_issue.dependencies == [issue2.id]
    end

    test "prevents duplicate dependencies", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create two issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})

      # Add issue2 as a dependency twice
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)
      {:ok, updated_issue} = Issues.add_dependency(issue1.id, issue2.id)

      # Should only have one occurrence
      assert updated_issue.dependencies == [issue2.id]
    end

    test "detects simple two-issue cycle", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create two issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})

      # Add issue2 as a dependency of issue1
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)

      # Try to add issue1 as a dependency of issue2 (would create a cycle)
      assert {:error, :cycle_detected} = Issues.add_dependency(issue2.id, issue1.id)

      # Verify issue2 still has no dependencies
      {:ok, loaded_issue2} = Issues.get(issue2.id)
      assert loaded_issue2.dependencies == []
    end

    test "detects three-issue cycle", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create three issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})
      {:ok, issue3} = Issues.create(%{title: "Issue 3", source: :user})

      # Create chain: issue1 -> issue2 -> issue3
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)
      {:ok, _} = Issues.add_dependency(issue2.id, issue3.id)

      # Try to complete the cycle: issue3 -> issue1
      assert {:error, :cycle_detected} = Issues.add_dependency(issue3.id, issue1.id)

      # Verify issue3 still has no dependencies
      {:ok, loaded_issue3} = Issues.get(issue3.id)
      assert loaded_issue3.dependencies == []
    end

    test "detects self-referential cycle", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create an issue
      {:ok, issue} = Issues.create(%{title: "Issue", source: :user})

      # Try to make it depend on itself
      assert {:error, :cycle_detected} = Issues.add_dependency(issue.id, issue.id)

      # Verify issue has no dependencies
      {:ok, loaded_issue} = Issues.get(issue.id)
      assert loaded_issue.dependencies == []
    end

    test "returns error when issue not found", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      {:ok, issue} = Issues.create(%{title: "Issue", source: :user})

      # Try to add dependency with non-existent issue ID
      assert {:error, :not_found} = Issues.add_dependency("deft-nonexistent", issue.id)
    end

    test "returns error when blocker not found", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      {:ok, issue} = Issues.create(%{title: "Issue", source: :user})

      # Try to add non-existent blocker
      assert {:error, :blocker_not_found} = Issues.add_dependency(issue.id, "deft-nonexistent")
    end

    test "allows adding multiple dependencies", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create issues
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})
      {:ok, issue3} = Issues.create(%{title: "Issue 3", source: :user})

      # Add multiple dependencies
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)
      {:ok, updated_issue} = Issues.add_dependency(issue1.id, issue3.id)

      # Should have both dependencies
      assert length(updated_issue.dependencies) == 2
      assert issue2.id in updated_issue.dependencies
      assert issue3.id in updated_issue.dependencies
    end
  end

  describe "gitattributes integration" do
    test "creates .gitattributes with merge=union on first issue creation", %{tmp_dir: tmp_dir} do
      # Set up a fake git repo structure
      repo_root = Path.join(tmp_dir, "test-repo")
      File.mkdir_p!(repo_root)
      git_dir = Path.join(repo_root, ".git")
      File.mkdir_p!(git_dir)

      # Configure mock to simulate git repo
      Application.put_env(:deft, :git_mock_response, {"#{repo_root}\n", 0})
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Change to repo_root so File.cwd!() returns it
      original_cwd = File.cwd!()

      try do
        File.cd!(repo_root)

        # Start Issues
        {:ok, _pid} = Issues.start_link()

        # Create an issue to trigger gitattributes creation
        {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

        # Verify .gitattributes was created
        gitattributes_path = Path.join(repo_root, ".gitattributes")
        assert File.exists?(gitattributes_path)

        # Verify it contains the required line
        content = File.read!(gitattributes_path)
        assert content =~ ".deft/issues.jsonl merge=union"
      after
        File.cd!(original_cwd)
      end
    end

    test "appends to existing .gitattributes if it doesn't contain the line", %{tmp_dir: tmp_dir} do
      # Set up a fake git repo structure
      repo_root = Path.join(tmp_dir, "test-repo")
      File.mkdir_p!(repo_root)
      git_dir = Path.join(repo_root, ".git")
      File.mkdir_p!(git_dir)

      # Create existing .gitattributes with other content
      gitattributes_path = Path.join(repo_root, ".gitattributes")
      File.write!(gitattributes_path, "*.png binary\n")

      # Configure mock to simulate git repo
      Application.put_env(:deft, :git_mock_response, {"#{repo_root}\n", 0})
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Change to repo_root
      original_cwd = File.cwd!()

      try do
        File.cd!(repo_root)

        # Start Issues
        {:ok, _pid} = Issues.start_link()

        # Create an issue to trigger gitattributes update
        {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

        # Verify .gitattributes contains both lines
        content = File.read!(gitattributes_path)
        assert content =~ "*.png binary"
        assert content =~ ".deft/issues.jsonl merge=union"
      after
        File.cd!(original_cwd)
      end
    end

    test "does not duplicate the line if it already exists", %{tmp_dir: tmp_dir} do
      # Set up a fake git repo structure
      repo_root = Path.join(tmp_dir, "test-repo")
      File.mkdir_p!(repo_root)
      git_dir = Path.join(repo_root, ".git")
      File.mkdir_p!(git_dir)

      # Create existing .gitattributes with the line already present
      gitattributes_path = Path.join(repo_root, ".gitattributes")
      File.write!(gitattributes_path, ".deft/issues.jsonl merge=union\n")

      # Configure mock to simulate git repo
      Application.put_env(:deft, :git_mock_response, {"#{repo_root}\n", 0})
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Change to repo_root
      original_cwd = File.cwd!()

      try do
        File.cd!(repo_root)

        # Start Issues
        {:ok, _pid} = Issues.start_link()

        # Create two issues
        {:ok, _issue1} = Issues.create(%{title: "Test issue 1", source: :user})
        {:ok, _issue2} = Issues.create(%{title: "Test issue 2", source: :user})

        # Verify .gitattributes still contains only one occurrence of the line
        content = File.read!(gitattributes_path)

        line_count =
          content |> String.split("\n") |> Enum.count(&(&1 == ".deft/issues.jsonl merge=union"))

        assert line_count == 1
      after
        File.cd!(original_cwd)
      end
    end

    test "skips gitattributes when not in a git repo", %{tmp_dir: tmp_dir} do
      # Configure mock to simulate not being in a git repo
      Application.put_env(:deft, :git_mock_response, {"fatal: not a git repository\n", 128})
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      # Change to tmp_dir
      original_cwd = File.cwd!()

      try do
        File.cd!(tmp_dir)

        # Start Issues
        {:ok, _pid} = Issues.start_link()

        # Create an issue
        {:ok, _issue} = Issues.create(%{title: "Test issue", source: :user})

        # Verify .gitattributes was NOT created
        gitattributes_path = Path.join(tmp_dir, ".gitattributes")
        refute File.exists?(gitattributes_path)
      after
        File.cd!(original_cwd)
      end
    end
  end

  describe "remove_dependency/2" do
    test "removes a dependency from an issue", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create two issues with a dependency
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)

      # Remove the dependency
      {:ok, updated_issue} = Issues.remove_dependency(issue1.id, issue2.id)

      assert updated_issue.dependencies == []
      assert updated_issue.id == issue1.id

      # Verify the removal was persisted
      {:ok, loaded_issue} = Issues.get(issue1.id)
      assert loaded_issue.dependencies == []
    end

    test "handles removing non-existent dependency gracefully", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      {:ok, issue} = Issues.create(%{title: "Issue", source: :user})

      # Try to remove a dependency that doesn't exist
      {:ok, updated_issue} = Issues.remove_dependency(issue.id, "deft-nonexistent")

      assert updated_issue.dependencies == []
    end

    test "removes only the specified dependency", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      # Create issues with multiple dependencies
      {:ok, issue1} = Issues.create(%{title: "Issue 1", source: :user})
      {:ok, issue2} = Issues.create(%{title: "Issue 2", source: :user})
      {:ok, issue3} = Issues.create(%{title: "Issue 3", source: :user})
      {:ok, _} = Issues.add_dependency(issue1.id, issue2.id)
      {:ok, _} = Issues.add_dependency(issue1.id, issue3.id)

      # Remove one dependency
      {:ok, updated_issue} = Issues.remove_dependency(issue1.id, issue2.id)

      # Should only have issue3 as a dependency
      assert updated_issue.dependencies == [issue3.id]
    end

    test "returns error when issue not found", %{file_path: file_path} do
      {:ok, _pid} = Issues.start_link(file_path: file_path)

      {:ok, issue} = Issues.create(%{title: "Issue", source: :user})

      # Try to remove dependency from non-existent issue
      assert {:error, :not_found} = Issues.remove_dependency("deft-nonexistent", issue.id)
    end
  end
end
