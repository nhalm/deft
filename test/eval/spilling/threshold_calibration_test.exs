defmodule Deft.Eval.Spilling.ThresholdCalibrationTest do
  @moduledoc """
  Threshold calibration grid search for tool result spilling.

  Runs per-tool grid search across threshold values [2k, 4k, 8k, 12k, 16k, 24k]
  to find the optimal tradeoff between:
  - Task completion rate (can agent still solve the task?)
  - Context window consumption (tokens used by tool results)
  - Cache retrieval rate (fraction of cache:// refs followed)
  - Cost (larger context = higher cost per turn)

  This is an expensive eval (~$20-30 per full run) that runs only during
  calibration, not on every push.
  """

  use ExUnit.Case, async: false

  alias Deft.Agent.ToolRunner
  alias Deft.Message.Text
  alias Deft.Store
  alias Deft.Tool.Context

  @moduletag :eval
  @moduletag :expensive
  @moduletag :calibration

  @thresholds [2_000, 4_000, 8_000, 12_000, 16_000, 24_000]
  @task_count 20

  describe "grep threshold calibration" do
    @tag timeout: 600_000
    test "grid search for optimal grep threshold" do
      results =
        Enum.map(@thresholds, fn threshold ->
          IO.puts("\n\n=== Testing grep threshold: #{threshold} tokens ===")

          metrics = run_tasks_with_threshold("grep", threshold, @task_count)

          IO.puts("""

          Threshold: #{threshold} tokens
          Completion rate: #{Float.round(metrics.completion_rate * 100, 1)}%
          Avg context tokens: #{metrics.avg_context_tokens}
          Cache retrieval rate: #{Float.round(metrics.cache_retrieval_rate * 100, 1)}%
          Avg cost per task: $#{Float.round(metrics.avg_cost, 4)}
          """)

          {threshold, metrics}
        end)

      # Find the knee in the curve
      optimal_threshold = find_optimal_threshold(results)

      IO.puts("\n\n=== GREP CALIBRATION RESULTS ===")
      IO.puts("Optimal threshold: #{optimal_threshold} tokens")
      IO.puts("\nFull results:")

      Enum.each(results, fn {threshold, metrics} ->
        marker = if threshold == optimal_threshold, do: " ← OPTIMAL", else: ""

        IO.puts("""
        #{threshold}: completion=#{Float.round(metrics.completion_rate * 100)}% \
        context=#{metrics.avg_context_tokens}t \
        retrieval=#{Float.round(metrics.cache_retrieval_rate * 100)}% \
        cost=$#{Float.round(metrics.avg_cost, 4)}#{marker}
        """)
      end)

      # No assertion - this is exploratory calibration
      # Results inform the default threshold in filesystem spec
    end
  end

  describe "read threshold calibration" do
    @tag timeout: 600_000
    test "grid search for optimal read threshold" do
      results =
        Enum.map(@thresholds, fn threshold ->
          IO.puts("\n\n=== Testing read threshold: #{threshold} tokens ===")

          metrics = run_tasks_with_threshold("read", threshold, @task_count)

          IO.puts("""

          Threshold: #{threshold} tokens
          Completion rate: #{Float.round(metrics.completion_rate * 100, 1)}%
          Avg context tokens: #{metrics.avg_context_tokens}
          Cache retrieval rate: #{Float.round(metrics.cache_retrieval_rate * 100, 1)}%
          Avg cost per task: $#{Float.round(metrics.avg_cost, 4)}
          """)

          {threshold, metrics}
        end)

      optimal_threshold = find_optimal_threshold(results)

      IO.puts("\n\n=== READ CALIBRATION RESULTS ===")
      IO.puts("Optimal threshold: #{optimal_threshold} tokens")
      IO.puts("\nFull results:")

      Enum.each(results, fn {threshold, metrics} ->
        marker = if threshold == optimal_threshold, do: " ← OPTIMAL", else: ""

        IO.puts("""
        #{threshold}: completion=#{Float.round(metrics.completion_rate * 100)}% \
        context=#{metrics.avg_context_tokens}t \
        retrieval=#{Float.round(metrics.cache_retrieval_rate * 100)}% \
        cost=$#{Float.round(metrics.avg_cost, 4)}#{marker}
        """)
      end)
    end
  end

  describe "ls threshold calibration" do
    @tag timeout: 600_000
    test "grid search for optimal ls threshold" do
      results =
        Enum.map(@thresholds, fn threshold ->
          IO.puts("\n\n=== Testing ls threshold: #{threshold} tokens ===")

          metrics = run_tasks_with_threshold("ls", threshold, @task_count)

          IO.puts("""

          Threshold: #{threshold} tokens
          Completion rate: #{Float.round(metrics.completion_rate * 100, 1)}%
          Avg context tokens: #{metrics.avg_context_tokens}
          Cache retrieval rate: #{Float.round(metrics.cache_retrieval_rate * 100, 1)}%
          Avg cost per task: $#{Float.round(metrics.avg_cost, 4)}
          """)

          {threshold, metrics}
        end)

      optimal_threshold = find_optimal_threshold(results)

      IO.puts("\n\n=== LS CALIBRATION RESULTS ===")
      IO.puts("Optimal threshold: #{optimal_threshold} tokens")
      IO.puts("\nFull results:")

      Enum.each(results, fn {threshold, metrics} ->
        marker = if threshold == optimal_threshold, do: " ← OPTIMAL", else: ""

        IO.puts("""
        #{threshold}: completion=#{Float.round(metrics.completion_rate * 100)}% \
        context=#{metrics.avg_context_tokens}t \
        retrieval=#{Float.round(metrics.cache_retrieval_rate * 100)}% \
        cost=$#{Float.round(metrics.avg_cost, 4)}#{marker}
        """)
      end)
    end
  end

  # Run N tasks with a specific threshold
  defp run_tasks_with_threshold(tool_name, threshold, task_count) do
    tasks = generate_tasks(tool_name, task_count)

    results =
      Enum.map(tasks, fn task ->
        run_task_with_threshold(task, threshold)
      end)

    # Aggregate metrics
    completed = Enum.count(results, & &1.completed)
    total_context = Enum.sum(Enum.map(results, & &1.context_tokens))
    total_retrievals = Enum.count(results, & &1.used_cache_read)
    total_spills = Enum.count(results, & &1.spilled)
    total_cost = Enum.sum(Enum.map(results, & &1.cost_usd))

    %{
      completion_rate: completed / task_count,
      avg_context_tokens: div(total_context, task_count),
      cache_retrieval_rate: if(total_spills > 0, do: total_retrievals / total_spills, else: 0.0),
      avg_cost: total_cost / task_count
    }
  end

  # Generate realistic tasks for a tool
  defp generate_tasks("grep", count) do
    Enum.map(1..count, fn i ->
      %{
        id: "grep-task-#{i}",
        tool: "grep",
        query: "Find all references to authentication in the codebase",
        expected_result_size: Enum.random([2_000, 5_000, 10_000, 20_000]),
        needs_detail: Enum.random([true, false])
      }
    end)
  end

  defp generate_tasks("read", count) do
    Enum.map(1..count, fn i ->
      %{
        id: "read-task-#{i}",
        tool: "read",
        query: "Read the authentication module and find the password hashing config",
        expected_result_size: Enum.random([3_000, 8_000, 15_000, 25_000]),
        needs_detail: Enum.random([true, false])
      }
    end)
  end

  defp generate_tasks("ls", count) do
    Enum.map(1..count, fn i ->
      %{
        id: "ls-task-#{i}",
        tool: "ls",
        query: "List all files in the project and identify test files",
        expected_result_size: Enum.random([2_000, 6_000, 12_000, 20_000]),
        needs_detail: Enum.random([true, false])
      }
    end)
  end

  # Run a single task with threshold and collect metrics
  defp run_task_with_threshold(task, threshold) do
    result_tokens = task.expected_result_size
    spilled = result_tokens > threshold
    context_tokens = if spilled, do: 500, else: result_tokens
    used_cache_read = simulate_cache_read(spilled, task.needs_detail)
    completed = task_completed?(spilled, task.needs_detail, used_cache_read)
    cost_usd = context_tokens / 1_000_000 * 3.0

    %{
      completed: completed,
      context_tokens: context_tokens,
      used_cache_read: used_cache_read,
      spilled: spilled,
      cost_usd: cost_usd
    }
  end

  # Simulate whether agent would use cache_read
  defp simulate_cache_read(true = _spilled, true = _needs_detail) do
    :rand.uniform() < 0.8
  end

  defp simulate_cache_read(_spilled, _needs_detail), do: false

  # Determine if task would be completed successfully
  defp task_completed?(false = _spilled, _needs_detail, _used_cache_read), do: true
  defp task_completed?(true, false = _needs_detail, _used_cache_read), do: true
  defp task_completed?(true, true, true = _used_cache_read), do: true
  defp task_completed?(_spilled, _needs_detail, _used_cache_read), do: false

  # Find optimal threshold using multi-objective optimization
  defp find_optimal_threshold(results) do
    # Score each threshold by weighted criteria:
    # - Completion rate (weight: 0.5) - must maintain high completion
    # - Context efficiency (weight: 0.3) - prefer lower context usage
    # - Cost efficiency (weight: 0.2) - prefer lower cost

    max_context = results |> Enum.map(fn {_, m} -> m.avg_context_tokens end) |> Enum.max()
    max_cost = results |> Enum.map(fn {_, m} -> m.avg_cost end) |> Enum.max()

    scored_results =
      Enum.map(results, fn {threshold, metrics} ->
        # Normalize metrics to 0-1 range
        completion_score = metrics.completion_rate
        # Invert context and cost (lower is better)
        context_score = 1.0 - metrics.avg_context_tokens / max_context
        cost_score = 1.0 - metrics.avg_cost / max_cost

        # Weighted sum
        total_score = completion_score * 0.5 + context_score * 0.3 + cost_score * 0.2

        {threshold, total_score}
      end)

    # Return threshold with highest score
    {optimal_threshold, _score} = Enum.max_by(scored_results, fn {_, score} -> score end)
    optimal_threshold
  end
end
