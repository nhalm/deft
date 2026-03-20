defmodule Deft.Eval.ResultStoreTest do
  use ExUnit.Case, async: false

  alias Deft.Eval.ResultStore

  @results_dir "test/eval/results"
  @test_run_prefix "test-run"

  setup do
    # Clean up any existing test results before each test
    cleanup_test_results()

    on_exit(fn ->
      cleanup_test_results()
    end)

    :ok
  end

  describe "generate_run_id/0" do
    test "generates unique run IDs with date prefix" do
      run_id1 = ResultStore.generate_run_id()
      run_id2 = ResultStore.generate_run_id()

      # Should start with today's date
      today = Date.utc_today() |> Date.to_iso8601()
      assert String.starts_with?(run_id1, today)
      assert String.starts_with?(run_id2, today)

      # Should be unique
      assert run_id1 != run_id2

      # Should match format: YYYY-MM-DD-<hex>
      assert run_id1 =~ ~r/^\d{4}-\d{2}-\d{2}-[0-9a-f]{6}$/
    end
  end

  describe "get_commit_sha/0" do
    test "returns commit SHA or unknown" do
      sha = ResultStore.get_commit_sha()

      # Should either be a valid SHA or "unknown"
      assert is_binary(sha)
      assert sha == "unknown" or String.match?(sha, ~r/^[0-9a-f]{40}$/)
    end
  end

  describe "store/1 and load/1" do
    test "stores and loads a result" do
      result = create_test_result("#{@test_run_prefix}-001")

      assert :ok = ResultStore.store(result)

      assert {:ok, results} = ResultStore.load(result.run_id)
      assert length(results) == 1

      [loaded] = results
      assert loaded.run_id == result.run_id
      assert loaded.commit == result.commit
      assert loaded.model == result.model
      assert loaded.category == result.category
      assert loaded.pass_rate == result.pass_rate
      assert loaded.iterations == result.iterations
      assert loaded.cost_usd == result.cost_usd
      assert length(loaded.failures) == length(result.failures)
    end

    test "returns error for non-existent run" do
      assert {:error, :not_found} = ResultStore.load("nonexistent-run-id")
    end

    test "stores failures with details" do
      result = %{
        create_test_result("#{@test_run_prefix}-002")
        | failures: [
            %{
              fixture: "observer-tech-choice-003",
              output: "some model output",
              reason: "Missing PostgreSQL in extraction"
            }
          ]
      }

      assert :ok = ResultStore.store(result)
      assert {:ok, results} = ResultStore.load(result.run_id)

      assert length(results) == 1
      [loaded] = results

      assert length(loaded.failures) == 1
      [failure] = loaded.failures
      assert failure.fixture == "observer-tech-choice-003"
      assert failure.output == "some model output"
      assert failure.reason == "Missing PostgreSQL in extraction"
    end

    test "multiple categories accumulate in the same run_id file" do
      run_id = "#{@test_run_prefix}-multi-category"

      # Store two different categories with the same run_id
      result1 = %{create_test_result(run_id) | category: "observer.extraction"}
      result2 = %{create_test_result(run_id) | category: "observer.priority"}

      assert :ok = ResultStore.store(result1)
      assert :ok = ResultStore.store(result2)

      # Load should return both results
      assert {:ok, results} = ResultStore.load(run_id)
      assert length(results) == 2

      # Verify both categories are present
      categories = Enum.map(results, & &1.category)
      assert "observer.extraction" in categories
      assert "observer.priority" in categories

      # Verify the file format is correct JSONL
      file_path = Path.join(@results_dir, "#{run_id}.jsonl")
      assert {:ok, content} = File.read(file_path)

      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2
    end

    test "skips corrupt JSONL lines and preserves valid results" do
      run_id = "#{@test_run_prefix}-corrupt"

      # Store two valid results
      result1 = %{create_test_result(run_id) | category: "observer.extraction"}
      result2 = %{create_test_result(run_id) | category: "observer.priority"}

      assert :ok = ResultStore.store(result1)
      assert :ok = ResultStore.store(result2)

      # Manually inject a corrupt line in the middle
      file_path = Path.join(@results_dir, "#{run_id}.jsonl")
      assert {:ok, content} = File.read(file_path)

      lines = String.split(content, "\n", trim: true)

      corrupted_content =
        Enum.at(lines, 0) <> "\n" <> "{invalid json here\n" <> Enum.at(lines, 1) <> "\n"

      File.write!(file_path, corrupted_content)

      # Load should skip the corrupt line and return the two valid results
      assert {:ok, results} = ResultStore.load(run_id)
      assert length(results) == 2

      # Verify both valid categories are present
      categories = Enum.map(results, & &1.category)
      assert "observer.extraction" in categories
      assert "observer.priority" in categories
    end

    test "returns empty list when all lines are corrupt" do
      run_id = "#{@test_run_prefix}-all-corrupt"

      # Create the file with only corrupt content
      file_path = Path.join(@results_dir, "#{run_id}.jsonl")
      File.mkdir_p!(@results_dir)
      File.write!(file_path, "{invalid json\n{also invalid\n")

      # Should return empty list, not error
      assert {:ok, results} = ResultStore.load(run_id)
      assert results == []
    end
  end

  describe "list_runs/0" do
    test "returns empty list when no results exist" do
      assert ResultStore.list_runs() == []
    end

    test "lists all runs sorted newest first" do
      # Create results with different dates
      run1 = create_test_result("2026-03-15-aaaaaa")
      run2 = create_test_result("2026-03-16-bbbbbb")
      run3 = create_test_result("2026-03-17-cccccc")

      ResultStore.store(run1)
      ResultStore.store(run2)
      ResultStore.store(run3)

      runs = ResultStore.list_runs()

      # Should be sorted newest first
      assert runs == ["2026-03-17-cccccc", "2026-03-16-bbbbbb", "2026-03-15-aaaaaa"]
    end

    test "excludes archive files from run list" do
      # Create regular run results
      run1 = create_test_result("2026-03-15-aaaaaa")
      run2 = create_test_result("2026-03-16-bbbbbb")

      ResultStore.store(run1)
      ResultStore.store(run2)

      # Create an archive file manually (simulating mix eval.export output)
      archive_path = Path.join(@results_dir, "archive-20260316T120000Z.jsonl")
      File.mkdir_p!(@results_dir)

      File.write!(archive_path, """
      {"run_id":"2026-03-01-archived","commit":"abc123","timestamp":"2026-03-01T10:00:00Z","model":"claude-sonnet-4-6","category":"test","pass_rate":0.9,"iterations":20,"cost_usd":0.5,"failures":[]}
      """)

      on_exit(fn ->
        File.rm(archive_path)
      end)

      runs = ResultStore.list_runs()

      # Should only include the two regular runs, not the archive file
      assert runs == ["2026-03-16-bbbbbb", "2026-03-15-aaaaaa"]
      assert "archive-20260316T120000Z" not in runs
    end
  end

  describe "cleanup_old_runs/0" do
    test "keeps only the last 30 runs" do
      # Create 35 test results
      results =
        Enum.map(1..35, fn i ->
          # Create with sequential dates to ensure ordering
          day = rem(i - 1, 28) + 1

          run_id =
            "2026-03-#{String.pad_leading(to_string(day), 2, "0")}-#{String.pad_leading(Integer.to_string(i, 16), 6, "0")}"

          create_test_result(run_id)
        end)

      # Store all results
      Enum.each(results, &ResultStore.store/1)

      # Should keep only 30
      remaining_runs = ResultStore.list_runs()
      assert length(remaining_runs) == 30

      # Should keep the newest 30
      expected_runs =
        results
        |> Enum.map(& &1.run_id)
        |> Enum.sort(:desc)
        |> Enum.take(30)

      assert remaining_runs == expected_runs
    end

    test "does nothing when less than 30 runs exist" do
      # Create 5 runs with proper date format
      Enum.each(1..5, fn i ->
        run_id =
          "2026-03-#{String.pad_leading(to_string(i), 2, "0")}-#{String.pad_leading(Integer.to_string(i, 16), 6, "0")}"

        result = create_test_result(run_id)
        ResultStore.store(result)
      end)

      ResultStore.cleanup_old_runs()

      # All 5 should still exist
      assert length(ResultStore.list_runs()) == 5
    end

    test "does not count archive files toward 30-run limit" do
      # Create 32 regular runs
      results =
        Enum.map(1..32, fn i ->
          day = rem(i - 1, 28) + 1

          run_id =
            "2026-03-#{String.pad_leading(to_string(day), 2, "0")}-#{String.pad_leading(Integer.to_string(i, 16), 6, "0")}"

          create_test_result(run_id)
        end)

      Enum.each(results, &ResultStore.store/1)

      # Create archive files (should not be counted)
      archive_path1 = Path.join(@results_dir, "archive-20260301T120000Z.jsonl")
      archive_path2 = Path.join(@results_dir, "archive-20260315T140000Z.jsonl")

      File.write!(archive_path1, """
      {"run_id":"2026-02-01-old","commit":"abc","timestamp":"2026-02-01T10:00:00Z","model":"claude-sonnet-4-6","category":"test","pass_rate":0.9,"iterations":20,"cost_usd":0.5,"failures":[]}
      """)

      File.write!(archive_path2, """
      {"run_id":"2026-02-15-old","commit":"def","timestamp":"2026-02-15T10:00:00Z","model":"claude-sonnet-4-6","category":"test","pass_rate":0.9,"iterations":20,"cost_usd":0.5,"failures":[]}
      """)

      on_exit(fn ->
        File.rm(archive_path1)
        File.rm(archive_path2)
      end)

      # Run cleanup - should only consider the 32 regular runs
      ResultStore.cleanup_old_runs()

      remaining_runs = ResultStore.list_runs()

      # Should keep 30 runs (not counting archives)
      assert length(remaining_runs) == 30

      # Archive files should still exist (not deleted by cleanup)
      assert File.exists?(archive_path1)
      assert File.exists?(archive_path2)

      # Should keep the newest 30 regular runs
      expected_runs =
        results
        |> Enum.map(& &1.run_id)
        |> Enum.sort(:desc)
        |> Enum.take(30)

      assert remaining_runs == expected_runs
    end
  end

  describe "export/1" do
    test "exports all results to a JSONL file" do
      # Create a few results with proper date format
      results = [
        create_test_result("2026-03-10-aaa001"),
        create_test_result("2026-03-11-aaa002"),
        create_test_result("2026-03-12-aaa003")
      ]

      Enum.each(results, &ResultStore.store/1)

      # Export to a temp file
      export_path = Path.join(System.tmp_dir!(), "eval-export-test.jsonl")

      on_exit(fn ->
        File.rm(export_path)
      end)

      assert :ok = ResultStore.export(export_path)

      # Verify the exported file
      assert {:ok, content} = File.read(export_path)

      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 3

      # Verify each line is valid JSON
      Enum.each(lines, fn line ->
        assert {:ok, _} = Jason.decode(line)
      end)
    end

    test "handles empty results directory" do
      export_path = Path.join(System.tmp_dir!(), "eval-export-empty-test.jsonl")

      on_exit(fn ->
        File.rm(export_path)
      end)

      assert :ok = ResultStore.export(export_path)

      # Should create an empty file
      assert {:ok, content} = File.read(export_path)
      assert String.trim(content) == ""
    end

    test "skips runs with corrupt data and exports valid runs" do
      # Create two valid results with proper date format
      result1 = create_test_result("2026-03-13-bbb001")
      result2 = create_test_result("2026-03-14-bbb002")

      ResultStore.store(result1)
      ResultStore.store(result2)

      # Create a run with corrupt data
      corrupt_run_id = "2026-03-15-corrupt"
      file_path = Path.join(@results_dir, "#{corrupt_run_id}.jsonl")
      File.mkdir_p!(@results_dir)
      File.write!(file_path, "{invalid json\n")

      # Export should skip the corrupt run and export valid ones
      export_path = Path.join(System.tmp_dir!(), "eval-export-skip-test.jsonl")

      on_exit(fn ->
        File.rm(export_path)
      end)

      assert :ok = ResultStore.export(export_path)

      # Verify only the valid results were exported
      assert {:ok, content} = File.read(export_path)

      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2

      # Verify each line is valid JSON
      Enum.each(lines, fn line ->
        assert {:ok, decoded} = Jason.decode(line)
        # Should not contain the corrupt run
        refute Map.get(decoded, "run_id") == corrupt_run_id
      end)
    end
  end

  # Helper functions

  defp create_test_result(run_id) do
    %{
      run_id: run_id,
      commit: "abc123def456",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: "claude-sonnet-4-6",
      category: "observer.extraction",
      pass_rate: 0.85,
      iterations: 20,
      cost_usd: 0.42,
      failures: []
    }
  end

  defp cleanup_test_results do
    # Remove all test results and any results from previous test runs
    case File.ls(@results_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file ->
          String.starts_with?(file, @test_run_prefix) or
            String.starts_with?(file, "2026-03-")
        end)
        |> Enum.each(fn file ->
          File.rm(Path.join(@results_dir, file))
        end)

      {:error, _} ->
        :ok
    end
  end
end
