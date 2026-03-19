defmodule Deft.Eval.Helpers do
  @moduledoc """
  Helper functions for AI eval tests.

  Provides utilities for:
  - Loading fixtures
  - Calling LLM judges
  - Storing eval results
  - Computing confidence intervals
  """

  @doc """
  Loads a codebase snapshot fixture.

  Returns a map of relative file paths to content.
  """
  def load_codebase_snapshot(path) do
    Path.wildcard("#{path}/**/*")
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(fn file_path ->
      relative_path = Path.relative_to(file_path, path)
      content = File.read!(file_path)
      {relative_path, content}
    end)
    |> Map.new()
  end

  @doc """
  Calls an LLM judge with a prompt and returns the result.

  Uses the configured judge model (default: claude-3-5-haiku-latest).
  """
  def call_llm_judge(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-3-5-haiku-latest")
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    # TODO: Implement actual LLM call when provider is available
    # For now, return a stub response
    {:ok, "Pending implementation"}
  end

  @doc """
  Computes Wilson score confidence interval for a proportion.

  Returns {lower_bound, upper_bound} for 95% confidence.
  """
  def confidence_interval(successes, total) do
    if total == 0 do
      {0.0, 0.0}
    else
      p = successes / total
      # 95% confidence
      z = 1.96
      n = total

      denominator = 1 + z * z / n
      center = (p + z * z / (2 * n)) / denominator
      margin = z * :math.sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator

      lower = max(0.0, center - margin)
      upper = min(1.0, center + margin)

      {Float.round(lower, 3), Float.round(upper, 3)}
    end
  end

  @doc """
  Stores eval results to a JSONL file.

  Creates test/eval/results/<run_id>.jsonl with results and metadata.
  """
  def store_results(category, results, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, generate_run_id())
    commit = Keyword.get(opts, :commit, get_git_commit())
    model = Keyword.get(opts, :model, "claude-sonnet-4-6")

    pass_count = Enum.count(results, & &1.pass)
    total = length(results)
    pass_rate = if total > 0, do: pass_count / total, else: 0.0

    failures =
      results
      |> Enum.reject(& &1.pass)
      |> Enum.map(fn result ->
        %{
          iteration: result.iteration,
          output: Map.get(result, :output, ""),
          reason: Map.get(result, :reason, "Unknown failure")
        }
      end)

    result_data = %{
      run_id: run_id,
      commit: commit,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: model,
      category: category,
      pass_rate: pass_rate,
      iterations: total,
      cost_usd: Keyword.get(opts, :cost_usd, 0.0),
      failures: failures
    }

    results_dir = "test/eval/results"
    File.mkdir_p!(results_dir)

    file_path = Path.join(results_dir, "#{run_id}.jsonl")
    json_line = Jason.encode!(result_data) <> "\n"

    File.write!(file_path, json_line, [:append])

    {:ok, run_id}
  end

  defp generate_run_id do
    date = Date.utc_today() |> Date.to_string()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{date}-#{random}"
  end

  defp get_git_commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> "unknown"
    end
  end
end
