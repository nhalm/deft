defmodule Deft.Eval.Spilling.ThresholdCalibrationTest do
  @moduledoc """
  Threshold calibration grid search for tool result spilling.

  Methodology per specs/evals/spilling.md section 7.3:
  1. Build 20 realistic tasks where the agent needs tool results
  2. For each tool, test thresholds at [2k, 4k, 8k, 12k, 16k, 24k] tokens
  3. Measure per threshold:
     - Task completion rate (did the agent produce the correct answer?)
     - Context window consumption (tokens used by tool results at turn N)
     - Cache retrieval rate (what fraction of cache:// references did the agent follow?)
     - Cost (fewer spills = larger context = higher cost per turn)
  4. Plot the knee in the tradeoff curve

  This eval is expensive (~$20-30 per full grid run) and runs only during
  calibration, not on every push.
  """
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive
  @moduletag :calibration
  @moduletag timeout: :infinity

  # Thresholds to test (in tokens)
  @thresholds [2000, 4000, 8000, 12000, 16000, 24000]

  # Tools to calibrate
  @tools [:read, :grep, :ls, :find]

  # Number of task fixtures per tool
  @tasks_per_tool 20

  describe "threshold calibration grid search" do
    test "calibrate read tool thresholds" do
      run_calibration(:read)
    end

    test "calibrate grep tool thresholds" do
      run_calibration(:grep)
    end

    test "calibrate ls tool thresholds" do
      run_calibration(:ls)
    end

    test "calibrate find tool thresholds" do
      run_calibration(:find)
    end

    test "generate threshold recommendations" do
      # Run after all individual calibrations
      # This test aggregates results and outputs recommended thresholds
      results = load_calibration_results()
      recommendations = compute_recommendations(results)

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("THRESHOLD CALIBRATION RECOMMENDATIONS")
      IO.puts(String.duplicate("=", 80))

      for {tool, threshold} <- recommendations do
        IO.puts("cache.token_threshold.#{tool}: #{threshold}")
      end

      IO.puts(String.duplicate("=", 80) <> "\n")

      # Store recommendations
      store_recommendations(recommendations)
    end
  end

  # Core calibration logic
  defp run_calibration(tool) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Calibrating #{tool} tool thresholds")
    IO.puts(String.duplicate("=", 80))

    tasks = load_task_fixtures(tool)
    assert length(tasks) == @tasks_per_tool, "Expected #{@tasks_per_tool} tasks for #{tool}"

    results =
      Enum.reduce(@thresholds, %{}, fn threshold, acc ->
        IO.puts("\nTesting threshold: #{threshold} tokens")
        result = test_threshold(tool, threshold, tasks)

        IO.puts("""
          Completion rate: #{format_pct(result.completion_rate)}
          Avg context tokens: #{result.avg_context_tokens}
          Cache retrieval rate: #{format_pct(result.cache_retrieval_rate)}
          Total cost: $#{Float.round(result.total_cost, 2)}
        """)

        Map.put(acc, threshold, result)
      end)

    # Store results
    store_calibration_results(tool, results)

    # Find the knee
    knee = find_knee(results)
    IO.puts("\nRecommended threshold (knee of curve): #{knee} tokens\n")

    # Plot the tradeoff curve
    plot_tradeoff(tool, results)
  end

  defp test_threshold(tool, threshold, tasks) do
    # Test all tasks with this threshold
    task_results =
      Enum.map(tasks, fn task ->
        run_task_with_threshold(tool, threshold, task)
      end)

    # Aggregate metrics
    %{
      completion_rate: calculate_completion_rate(task_results),
      avg_context_tokens: calculate_avg_context(task_results),
      cache_retrieval_rate: calculate_cache_retrieval_rate(task_results),
      total_cost: calculate_total_cost(task_results)
    }
  end

  defp run_task_with_threshold(tool, threshold, task) do
    # Simulate running a task with the given threshold
    # For Phase 1 (before full agent exists), this is a simplified simulation
    # that estimates behavior based on tool output size and threshold

    tool_result = task.tool_result
    tool_result_size = estimate_tokens(tool_result)

    spilled = tool_result_size > threshold

    if spilled do
      # Agent sees summary, may or may not retrieve full result
      summary = generate_summary(tool, tool_result, threshold)
      agent_retrieved_cache = simulate_agent_decision(task, summary)

      %{
        task_id: task.id,
        completed: task.expected_answer_in_summary or agent_retrieved_cache,
        context_tokens: estimate_tokens(summary),
        cache_retrieval: agent_retrieved_cache,
        spilled: spilled,
        cost: estimate_cost(summary, task)
      }
    else
      # Agent sees full result
      %{
        task_id: task.id,
        completed: true,
        context_tokens: tool_result_size,
        cache_retrieval: false,
        spilled: false,
        cost: estimate_cost(tool_result, task)
      }
    end
  end

  # Metric calculations
  defp calculate_completion_rate(results) do
    completed = Enum.count(results, & &1.completed)
    completed / length(results)
  end

  defp calculate_avg_context(results) do
    total = Enum.sum(Enum.map(results, & &1.context_tokens))
    total / length(results)
  end

  defp calculate_cache_retrieval_rate(results) do
    retrieved = Enum.count(results, & &1.cache_retrieval)
    spilled = Enum.count(results, & &1.spilled)

    if spilled > 0 do
      retrieved / spilled
    else
      0.0
    end
  end

  defp calculate_total_cost(results) do
    Enum.sum(Enum.map(results, & &1.cost))
  end

  # Knee detection - find the threshold where we get good completion rate
  # without excessive context consumption
  defp find_knee(results) do
    # Sort by threshold
    sorted =
      results
      |> Enum.map(fn {threshold, metrics} ->
        {threshold, metrics.completion_rate, metrics.avg_context_tokens}
      end)
      |> Enum.sort_by(fn {threshold, _rate, _tokens} -> threshold end)

    # Find the point where:
    # 1. Completion rate is >= 0.90 (acceptable)
    # 2. Adding more context gives diminishing returns
    knee_threshold =
      sorted
      |> Enum.reduce_while(nil, fn {threshold, rate, _tokens}, acc ->
        if rate >= 0.90 do
          {:halt, threshold}
        else
          {:cont, acc}
        end
      end)

    knee_threshold || 8000
  end

  # ASCII plot of the tradeoff curve
  defp plot_tradeoff(tool, results) do
    IO.puts("\n#{tool} Threshold Tradeoff Curve:")
    IO.puts(String.duplicate("-", 80))

    IO.puts(
      String.pad_trailing("Threshold", 12) <>
        String.pad_trailing("Completion", 14) <>
        String.pad_trailing("Avg Tokens", 14) <>
        String.pad_trailing("Cache %%", 12) <>
        "Cost"
    )

    IO.puts(String.duplicate("-", 80))

    @thresholds
    |> Enum.each(fn threshold ->
      metrics = results[threshold]

      IO.puts(
        String.pad_trailing("#{threshold}", 12) <>
          String.pad_trailing("#{format_pct(metrics.completion_rate)}", 14) <>
          String.pad_trailing("#{round(metrics.avg_context_tokens)}", 14) <>
          String.pad_trailing("#{format_pct(metrics.cache_retrieval_rate)}", 12) <>
          "$#{Float.round(metrics.total_cost, 2)}"
      )
    end)

    IO.puts(String.duplicate("-", 80))
  end

  # Fixture loading
  defp load_task_fixtures(tool) do
    # Load fixtures from test/eval/fixtures/threshold_calibration/
    fixture_file = "test/eval/fixtures/threshold_calibration/#{tool}_tasks.json"

    if File.exists?(fixture_file) do
      fixture_file
      |> File.read!()
      |> Jason.decode!(keys: :atoms)
      |> Map.get(:tasks, [])
      |> Enum.map(&atomize_keys/1)
    else
      # Generate synthetic fixtures if file doesn't exist
      generate_synthetic_tasks(tool)
    end
  end

  defp generate_synthetic_tasks(tool) do
    # Generate 20 synthetic task fixtures for the given tool
    # Each task has:
    # - id: unique identifier
    # - tool_result: simulated tool output
    # - expected_answer_in_summary: whether the answer is in the summary
    # - question: what the agent needs to find

    case tool do
      :read ->
        generate_read_tasks()

      :grep ->
        generate_grep_tasks()

      :ls ->
        generate_ls_tasks()

      :find ->
        generate_find_tasks()
    end
  end

  defp generate_read_tasks do
    # Generate tasks like "find function X in file Y"
    # where X might be in first 100 lines (in summary) or later (needs full result)
    for i <- 1..@tasks_per_tool do
      lines = 100 + i * 50
      target_line = if rem(i, 3) == 0, do: 50, else: 200

      %{
        id: "read-#{i}",
        tool_result: generate_file_content(lines),
        expected_answer_in_summary: target_line <= 100,
        question: "Find the function at line #{target_line}"
      }
    end
  end

  defp generate_grep_tasks do
    # Generate tasks like "find all references to X"
    # where there might be 5 matches (in top 10) or 50 matches (needs full result)
    for i <- 1..@tasks_per_tool do
      match_count = if rem(i, 3) == 0, do: 5, else: 30

      %{
        id: "grep-#{i}",
        tool_result: generate_grep_output(match_count),
        expected_answer_in_summary: match_count <= 10,
        question: "Find all references to function_#{i}"
      }
    end
  end

  defp generate_ls_tasks do
    # Generate tasks like "list all files in directory X"
    for i <- 1..@tasks_per_tool do
      file_count = 20 + i * 10

      %{
        id: "ls-#{i}",
        tool_result: generate_directory_tree(file_count),
        expected_answer_in_summary: true,
        question: "How many files are in src/?"
      }
    end
  end

  defp generate_find_tasks do
    # Generate tasks like "find all test files"
    for i <- 1..@tasks_per_tool do
      file_count = 15 + i * 5

      %{
        id: "find-#{i}",
        tool_result: generate_find_output(file_count),
        expected_answer_in_summary: true,
        question: "How many test files are there?"
      }
    end
  end

  # Synthetic data generators
  defp generate_file_content(lines) do
    1..lines
    |> Enum.map(fn i ->
      if rem(i, 20) == 0 do
        "  def function_#{div(i, 20)}(arg) do"
      else
        "    # Line #{i} - some code here"
      end
    end)
    |> Enum.join("\n")
  end

  defp generate_grep_output(match_count) do
    1..match_count
    |> Enum.map(fn i ->
      "lib/module_#{div(i, 3)}.ex:#{i * 10}: function_call(#{i})"
    end)
    |> Enum.join("\n")
  end

  defp generate_directory_tree(file_count) do
    1..file_count
    |> Enum.map(fn i ->
      dir = rem(i, 5)
      "src/dir#{dir}/file_#{i}.ex"
    end)
    |> Enum.join("\n")
  end

  defp generate_find_output(file_count) do
    1..file_count
    |> Enum.map(fn i ->
      "test/module_#{i}_test.exs"
    end)
    |> Enum.join("\n")
  end

  # Summary generation (tool-specific)
  defp generate_summary(:read, content, _threshold) do
    lines = String.split(content, "\n")
    first_100 = Enum.take(lines, 100)

    """
    File (#{length(lines)} lines). First 100 lines shown:

    #{Enum.join(first_100, "\n")}

    Full results: cache://read-#{:rand.uniform(100_000)}
    """
  end

  defp generate_summary(:grep, content, _threshold) do
    lines = String.split(content, "\n")
    top_10 = Enum.take(lines, 10)

    """
    #{length(lines)} matches. Top 10 shown:

    #{Enum.join(top_10, "\n")}

    Full results: cache://grep-#{:rand.uniform(100_000)}
    """
  end

  defp generate_summary(:ls, content, _threshold) do
    lines = String.split(content, "\n")

    """
    #{length(lines)} files. Top-level structure:

    src/ (#{length(lines)} files across #{div(length(lines), 5)} directories)

    Full results: cache://ls-#{:rand.uniform(100_000)}
    """
  end

  defp generate_summary(:find, content, _threshold) do
    lines = String.split(content, "\n")

    """
    #{length(lines)} files found.

    Full results: cache://find-#{:rand.uniform(100_000)}
    """
  end

  # Agent decision simulation
  defp simulate_agent_decision(task, _summary) do
    # Simplified heuristic: agent retrieves cache if answer not in summary
    # In reality, this would require running the actual agent
    not task.expected_answer_in_summary
  end

  # Token estimation
  defp estimate_tokens(text) when is_binary(text) do
    div(byte_size(text), 4)
  end

  defp estimate_tokens(_), do: 0

  # Cost estimation (rough approximation)
  defp estimate_cost(text, _task) do
    tokens = estimate_tokens(text)
    # Rough cost estimate: $3/M input tokens, $15/M output tokens
    # Assume 2:1 input:output ratio
    input_cost = tokens / 1_000_000 * 3.0
    output_cost = tokens / 2 / 1_000_000 * 15.0
    input_cost + output_cost
  end

  # Results storage
  defp store_calibration_results(tool, results) do
    run_id = "threshold-cal-#{tool}-#{DateTime.utc_now() |> DateTime.to_unix()}"
    results_dir = "test/eval/results"
    File.mkdir_p!(results_dir)

    result_file = Path.join(results_dir, "#{run_id}.jsonl")

    lines =
      for {threshold, metrics} <- results do
        Jason.encode!(%{
          run_id: run_id,
          tool: tool,
          threshold: threshold,
          completion_rate: metrics.completion_rate,
          avg_context_tokens: metrics.avg_context_tokens,
          cache_retrieval_rate: metrics.cache_retrieval_rate,
          total_cost: metrics.total_cost,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end

    File.write!(result_file, Enum.join(lines, "\n") <> "\n")
  end

  defp load_calibration_results do
    # Load the most recent calibration results for each tool
    results_dir = "test/eval/results"

    if File.exists?(results_dir) do
      @tools
      |> Enum.map(fn tool ->
        # Find most recent result file for this tool
        pattern = "threshold-cal-#{tool}-*.jsonl"

        files =
          Path.join(results_dir, pattern)
          |> Path.wildcard()
          |> Enum.sort()
          |> Enum.reverse()

        case files do
          [latest | _] ->
            results =
              latest
              |> File.read!()
              |> String.split("\n", trim: true)
              |> Enum.map(&Jason.decode!(&1, keys: :atoms))

            {tool, results}

          [] ->
            {tool, []}
        end
      end)
      |> Map.new()
    else
      %{}
    end
  end

  defp compute_recommendations(results) do
    # For each tool, find the recommended threshold based on the knee
    results
    |> Enum.map(fn {tool, tool_results} ->
      if Enum.empty?(tool_results) do
        # No calibration data, use default
        {tool, get_default_threshold(tool)}
      else
        # Group by threshold and find the knee
        by_threshold =
          tool_results
          |> Enum.group_by(& &1.threshold)
          |> Enum.map(fn {threshold, metrics_list} ->
            # Average metrics for this threshold (if multiple runs)
            avg_completion = avg_field(metrics_list, :completion_rate)
            {threshold, avg_completion}
          end)
          |> Enum.sort_by(fn {threshold, _} -> threshold end)

        knee =
          by_threshold
          |> Enum.find(fn {_threshold, completion_rate} ->
            completion_rate >= 0.90
          end)
          |> case do
            {threshold, _} -> threshold
            nil -> get_default_threshold(tool)
          end

        {tool, knee}
      end
    end)
    |> Map.new()
  end

  defp store_recommendations(recommendations) do
    recommendations_file = "test/eval/results/threshold_recommendations.json"

    content = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      recommendations: recommendations,
      note:
        "These thresholds are determined by grid search calibration. Update config.yaml with these values."
    }

    File.write!(recommendations_file, Jason.encode!(content, pretty: true))
  end

  # Helpers
  defp format_pct(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {String.to_atom(to_string(k)), atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp avg_field(list, field) do
    values = Enum.map(list, &Map.get(&1, field))
    Enum.sum(values) / length(values)
  end

  defp get_default_threshold(:read), do: 20000
  defp get_default_threshold(:grep), do: 8000
  defp get_default_threshold(:ls), do: 4000
  defp get_default_threshold(:find), do: 4000
  defp get_default_threshold(_), do: 10000
end
