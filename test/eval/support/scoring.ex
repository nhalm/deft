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
  def format_report(_category, _pass_count, _total, _threshold) do
    # TODO: Implement report formatting
    # - Compute pass rate and CI
    # - Compare to threshold
    # - Return formatted string
    {:error, :not_implemented}
  end
end
