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
      if Process.whereis(Issues) do
        GenServer.stop(Issues, :normal)
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
      assert log =~ "Cycle detected in dependencies for issue deft-aaa1"
      assert log =~ "Cycle detected in dependencies for issue deft-bbb2"

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
      assert log =~ "Cycle detected in dependencies for issue deft-aaa3"
      assert log =~ "Cycle detected in dependencies for issue deft-bbb4"
      assert log =~ "Cycle detected in dependencies for issue deft-ccc5"

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
      assert log =~ "Cycle detected in dependencies for issue deft-self"

      # Verify dependency was cleared
      {:ok, loaded_issue} = Issues.get("deft-self")
      assert loaded_issue.dependencies == []
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
end
