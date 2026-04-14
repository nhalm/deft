defmodule Eval.Support.Scoring do
  @moduledoc """
  Scoring and regression detection for eval results.
  Implements proportion z-tests for regression detection and baseline management.
  """

  # Spec: specs/testing/evals/README.md §2.3

  @doc """
  Detects significant regression using proportion z-test.

  Compares current run against historical pass rates.
  Returns true if regression is statistically significant (p < 0.05).

  ## Parameters
  - current_rate: Pass rate for current run (0.0-1.0)
  - current_n: Number of iterations in current run
  - historical_rates: List of historical pass rates

  ## Returns
  Boolean indicating significant regression
  """
  def significant_regression?(current_rate, current_n, historical_rates) do
    # Guard: no regression can be detected without history
    if historical_rates == [] do
      false
    else
      # Calculate mean of historical rates
      pooled = Enum.sum(historical_rates) / length(historical_rates)

      # Guard: pooled at boundaries makes z-test degenerate.
      # Apply Laplace smoothing or return false.
      cond do
        pooled == 0.0 or pooled == 1.0 ->
          # Laplace smoothing: shift pooled slightly away from boundary
          n = length(historical_rates)
          pooled = (pooled * n + 0.5) / (n + 1)
          se = :math.sqrt(pooled * (1 - pooled) / current_n)
          z = (current_rate - pooled) / se
          z < -1.645

        true ->
          se = :math.sqrt(pooled * (1 - pooled) / current_n)
          z = (current_rate - pooled) / se
          # p < 0.05 one-tailed
          z < -1.645
      end
    end
  end

  @doc """
  Checks if failures indicate infrastructure bug vs model quality regression.

  Returns :infrastructure_bug if same error appears in 80%+ of failures.
  Returns :quality_regression otherwise.
  """
  def classify_regression(_failures) do
    # TODO: Implement failure classification
    # - Group failures by error message/reason
    # - If one error dominates (8/10 failures), it's likely infrastructure
    # - Otherwise, it's model quality variance
    {:error, :not_implemented}
  end

  @doc """
  Formats pass rate report with confidence interval.

  Example output:
  "observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS"
  """
  def format_report(category, pass_count, total, threshold) when total > 0 do
    pass_rate = pass_count / total
    {ci_lower, ci_upper} = wilson_score_interval(pass_count, total)

    rate_pct = round(pass_rate * 100)
    ci_low_pct = round(ci_lower * 100)
    ci_high_pct = round(ci_upper * 100)

    status = determine_status(pass_rate, threshold)
    suffix = if status == "WARN", do: " ← investigate", else: ""

    "#{category}: #{pass_count}/#{total} (#{rate_pct}%) [CI: #{ci_low_pct}%-#{ci_high_pct}%] #{status}#{suffix}"
  end

  @doc """
  Calculates Wilson score confidence interval for a binomial proportion.

  Uses 95% confidence level (z = 1.96). The Wilson score interval is more
  accurate than the normal approximation for small sample sizes.
  """
  def wilson_score_interval(successes, n) when n > 0 do
    p = successes / n
    # 95% confidence level
    z = 1.96
    z_squared = z * z

    denominator = 1 + z_squared / n
    center = (p + z_squared / (2 * n)) / denominator

    variance = p * (1 - p) / n + z_squared / (4 * n * n)
    margin = z * :math.sqrt(variance) / denominator

    lower = max(0.0, center - margin)
    upper = min(1.0, center + margin)

    {lower, upper}
  end

  @doc """
  Determines PASS/FAIL/WARN status based on pass rate and threshold.

  - PASS: rate >= threshold
  - WARN: rate < threshold (needs investigation)
  - FAIL: For hard assertions (100% threshold) only
  """
  def determine_status(rate, threshold) do
    cond do
      rate >= threshold -> "PASS"
      # Hard assertions fail immediately
      threshold >= 1.0 -> "FAIL"
      true -> "WARN"
    end
  end
end
