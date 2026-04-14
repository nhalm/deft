defmodule Eval.Support.EvalHelpers do
  @moduledoc """
  Shared utilities for AI evaluation tests.

  Provides fixture loading, iteration runners, and confidence interval computation
  as prescribed in specs/testing/evals/README.md §1.3 and §1.5.
  """

  # Spec: specs/testing/evals/README.md §1.3-1.7

  @doc """
  Load a fixture from a JSON file.

  Returns a map with the fixture structure:
  - id: unique fixture identifier
  - spec_version: version of the spec this fixture targets
  - description: human-readable description
  - tags: list of category tags
  - messages: list of message maps for the LLM
  - context: additional context data
  - assertions: list of assertion definitions

  ## Examples

      iex> EvalHelpers.load_fixture("test/eval/fixtures/observer-tech-choice-001.json")
      %{
        "id" => "observer-explicit-tech-choice-001",
        "spec_version" => "0.1",
        "description" => "User explicitly states a technology choice",
        "tags" => ["observer", "extraction", "red-priority"],
        "messages" => [...],
        "context" => %{},
        "assertions" => [...]
      }
  """
  def load_fixture(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Load all fixtures from a directory matching a glob pattern.

  Returns a list of fixture maps.

  ## Examples

      iex> EvalHelpers.load_fixtures("test/eval/fixtures/observer-*.json")
      [%{"id" => "observer-001", ...}, %{"id" => "observer-002", ...}]
  """
  def load_fixtures(glob_pattern) do
    glob_pattern
    |> Path.wildcard()
    |> Enum.map(&load_fixture/1)
  end

  @doc """
  Loads holdout fixtures (never used during prompt development).

  Loads fixtures from test/eval/fixtures/holdout/ for the given category.
  These represent 20-30% of total fixtures and are only run to validate
  that prompts generalize beyond development fixtures.
  """
  def load_holdout_fixtures(category) do
    load_fixtures("test/eval/fixtures/holdout/#{category}-*.json")
  end

  @doc """
  Run a test function N times and collect pass/fail results.

  The test function should return `{:ok, result}` on pass or `{:error, reason}` on fail.
  Returns a map with pass/fail counts and details.

  ## Examples

      iex> EvalHelpers.run_iterations(20, fn -> {:ok, "success"} end)
      %{
        iterations: 20,
        passes: 20,
        failures: 0,
        pass_rate: 1.0,
        results: [{:ok, "success"}, ...]
      }
  """
  def run_iterations(n, test_fn) when is_integer(n) and n > 0 do
    results =
      1..n
      |> Enum.map(fn _i -> test_fn.() end)

    passes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failures = n - passes
    pass_rate = passes / n

    %{
      iterations: n,
      passes: passes,
      failures: failures,
      pass_rate: pass_rate,
      results: results
    }
  end

  @doc """
  Compute 95% confidence interval for a pass rate using Wilson score interval.

  The Wilson score interval is more accurate than the normal approximation,
  especially for small sample sizes or extreme probabilities.

  Returns a tuple {lower_bound, upper_bound} as percentages (0.0 to 100.0).

  ## Examples

      iex> EvalHelpers.confidence_interval(17, 20)
      {62.1, 96.8}

      iex> EvalHelpers.confidence_interval(20, 20)
      {83.2, 100.0}
  """
  def confidence_interval(successes, total, _confidence_level \\ 0.95)
      when successes >= 0 and total > 0 do
    {lower, upper} = wilson_score_interval(successes / total, total, 1.96)
    {Float.round(lower * 100, 1), Float.round(upper * 100, 1)}
  end

  defp wilson_score_interval(p, n, z) do
    # https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval
    z_sq = z * z
    denominator = 1 + z_sq / n
    center = (p + z_sq / (2 * n)) / denominator
    margin = z * :math.sqrt((p * (1 - p) / n + z_sq / (4 * n * n)) / denominator)

    {max(0.0, center - margin), min(1.0, center + margin)}
  end

  @doc """
  Format pass rate with confidence interval.

  Returns a string in the format prescribed by §1.5:
  `category: X/Y (Z%) [CI: lo%-hi%] PASS/FAIL`

  ## Examples

      iex> EvalHelpers.format_result("observer.extraction", 17, 20, 0.85)
      "observer.extraction: 17/20 (85.0%) [CI: 62.1%-96.8%] PASS"

      iex> EvalHelpers.format_result("foreman.decomposition", 12, 20, 0.75)
      "foreman.decomposition: 12/20 (60.0%) [CI: 36.1%-80.9%] FAIL"
  """
  def format_result(category, passes, total, threshold) do
    pass_rate = passes / total
    {ci_lower, ci_upper} = confidence_interval(passes, total)
    status = if pass_rate >= threshold, do: "PASS", else: "FAIL"

    pct = Float.round(pass_rate * 100, 1)

    "#{category}: #{passes}/#{total} (#{pct}%) [CI: #{ci_lower}%-#{ci_upper}%] #{status}"
  end

  @doc """
  Check if a pass rate represents a significant regression compared to historical rates.

  Uses a proportion z-test with p < 0.05 (one-tailed). Returns true if the current
  rate is significantly below the historical mean.

  ## Examples

      iex> EvalHelpers.significant_regression?(0.70, 20, [0.85, 0.88, 0.90])
      true

      iex> EvalHelpers.significant_regression?(0.85, 20, [0.85, 0.88, 0.90])
      false
  """
  def significant_regression?(current_rate, current_n, historical_rates) do
    # Guard: no regression can be detected without history
    if historical_rates == [] do
      false
    else
      pooled = Enum.sum(historical_rates) / length(historical_rates)

      # Guard: pooled at boundaries makes z-test degenerate.
      # Apply Laplace smoothing or return false.
      cond do
        pooled == 0.0 or pooled == 1.0 ->
          # Laplace smoothing: shift pooled slightly away from boundary
          n = length(historical_rates)
          pooled_smoothed = (pooled * n + 0.5) / (n + 1)
          se = :math.sqrt(pooled_smoothed * (1 - pooled_smoothed) / current_n)
          z = (current_rate - pooled_smoothed) / se
          z < -1.645

        true ->
          se = :math.sqrt(pooled * (1 - pooled) / current_n)
          z = (current_rate - pooled) / se
          z < -1.645
      end
    end
  end

  @doc """
  Extract failure examples from iteration results.

  Returns a list of maps with fixture ID and failure reason.

  ## Examples

      iex> results = [
      ...>   {:ok, %{fixture: "test-001"}},
      ...>   {:error, %{fixture: "test-002", reason: "Missing extraction"}},
      ...>   {:error, %{fixture: "test-003", reason: "Wrong section"}}
      ...> ]
      iex> EvalHelpers.extract_failures(results)
      [
        %{fixture: "test-002", reason: "Missing extraction"},
        %{fixture: "test-003", reason: "Wrong section"}
      ]
  """
  def extract_failures(results) do
    results
    |> Enum.filter(fn r -> match?({:error, _}, r) end)
    |> Enum.map(fn {:error, details} -> details end)
  end
end
