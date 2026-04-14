defmodule Deft.EvalSupport.Scoring do
  @moduledoc """
  Scoring functions for AI eval tests.

  Provides statistical analysis for eval results:
  - Pass rate calculation
  - Confidence intervals
  - Regression detection
  """

  @doc """
  Calculate pass rate from successes and total iterations.

  Returns a float between 0.0 and 1.0.

  ## Examples

      iex> calculate_pass_rate(17, 20)
      0.85

      iex> calculate_pass_rate(0, 20)
      0.0
  """
  def calculate_pass_rate(successes, total) when total > 0 do
    successes / total
  end

  def calculate_pass_rate(0, 0), do: 0.0

  @doc """
  Calculate Wilson score confidence interval for a proportion.

  Returns a tuple {lower_bound, upper_bound} at 95% confidence level.

  ## Examples

      iex> confidence_interval(17, 20)
      {0.62, 0.97}
  """
  def confidence_interval(successes, total) do
    p = calculate_pass_rate(successes, total)
    n = total

    # Wilson score interval at 95% confidence (z = 1.96)
    z = 1.96

    denominator = 1 + z * z / n
    center = p + z * z / (2 * n)
    margin = z * :math.sqrt((p * (1 - p) + z * z / (4 * n)) / n)

    lower = (center - margin) / denominator
    upper = (center + margin) / denominator

    {Float.round(lower, 2), Float.round(upper, 2)}
  end

  @doc """
  Detect statistically significant regression using proportion z-test.

  Compares current pass rate against historical distribution using a
  one-tailed z-test at p < 0.05 significance level.

  Returns true if current rate is significantly below historical mean.

  ## Examples

      iex> significant_regression?(0.60, 20, [0.85, 0.88, 0.87])
      true

      iex> significant_regression?(0.87, 20, [0.85, 0.88, 0.87])
      false

      iex> significant_regression?(0.85, 20, [])
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
      pooled =
        cond do
          pooled == 0.0 or pooled == 1.0 ->
            # Laplace smoothing: shift pooled slightly away from boundary
            n = length(historical_rates)
            (pooled * n + 0.5) / (n + 1)

          true ->
            pooled
        end

      se = :math.sqrt(pooled * (1 - pooled) / current_n)
      z = (current_rate - pooled) / se
      # p < 0.05 one-tailed (z < -1.645)
      z < -1.645
    end
  end

  @doc """
  Format eval results for display.

  Returns a string in the format:
  "category: successes/total (rate%) [CI: lower%-upper%] STATUS"

  ## Examples

      iex> format_result("observer.extraction", 17, 20, 0.85)
      "observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS"

      iex> format_result("foreman.decomposition", 12, 20, 0.75, threshold: 0.75)
      "foreman.decomposition: 12/20 (75%) [CI: 51%-91%] PASS"
  """
  def format_result(category, successes, total, threshold, opts \\ []) do
    rate = calculate_pass_rate(successes, total)
    {ci_lower, ci_upper} = confidence_interval(successes, total)

    threshold = Keyword.get(opts, :threshold, threshold)
    status = if rate >= threshold, do: "PASS", else: "WARN"

    rate_pct = Float.round(rate * 100, 0) |> trunc()
    ci_lower_pct = Float.round(ci_lower * 100, 0) |> trunc()
    ci_upper_pct = Float.round(ci_upper * 100, 0) |> trunc()

    "#{category}: #{successes}/#{total} (#{rate_pct}%) [CI: #{ci_lower_pct}%-#{ci_upper_pct}%] #{status}"
  end

  @doc """
  Check if current rate is below soft floor.

  Soft floor is baseline minus 10 percentage points.

  ## Examples

      iex> below_soft_floor?(0.75, 0.88)
      true

      iex> below_soft_floor?(0.80, 0.88)
      false
  """
  def below_soft_floor?(current_rate, baseline) do
    soft_floor = baseline - 0.10
    current_rate < soft_floor
  end
end
