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

      assert {:ok, loaded} = ResultStore.load(result.run_id)
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
      assert {:ok, loaded} = ResultStore.load(result.run_id)

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

      # Verify both results are in the file
      file_path = Path.join(@results_dir, "#{run_id}.jsonl")
      assert {:ok, content} = File.read(file_path)

      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2

      # Verify both categories are present
      [line1, line2] = lines
      assert {:ok, decoded1} = Jason.decode(line1, keys: :atoms)
      assert {:ok, decoded2} = Jason.decode(line2, keys: :atoms)

      categories = [decoded1.category, decoded2.category]
      assert "observer.extraction" in categories
      assert "observer.priority" in categories
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
      # Create 5 runs
      Enum.each(1..5, fn i ->
        result =
          create_test_result("#{@test_run_prefix}-#{String.pad_leading(to_string(i), 3, "0")}")

        ResultStore.store(result)
      end)

      ResultStore.cleanup_old_runs()

      # All 5 should still exist
      assert length(ResultStore.list_runs()) == 5
    end
  end

  describe "export/1" do
    test "exports all results to a JSONL file" do
      # Create a few results
      results = [
        create_test_result("#{@test_run_prefix}-exp-001"),
        create_test_result("#{@test_run_prefix}-exp-002"),
        create_test_result("#{@test_run_prefix}-exp-003")
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
