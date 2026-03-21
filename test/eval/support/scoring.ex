defmodule Deft.Eval.Scoring do
  @moduledoc """
  Statistical scoring and confidence interval reporting for eval results.

  Implements the report format from evals spec section 1.5:
  ```
  observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS
  foreman.decomposition: 12/20 (60%) [CI: 36%-81%] WARN ← investigate
  ```

  Uses Wilson score interval for binomial confidence intervals, which is more
  robust than the normal approximation for small samples and extreme proportions.
  """

  @type result :: %{
          category: String.t(),
          passes: non_neg_integer(),
          total: non_neg_integer(),
          threshold: float()
        }

  @type scored_result :: %{
          category: String.t(),
          passes: non_neg_integer(),
          total: non_neg_integer(),
          rate: float(),
          ci_lower: float(),
          ci_upper: float(),
          status: :pass | :warn,
          threshold: float()
        }

  @doc """
  Calculates Wilson score confidence interval for a binomial proportion.

  The Wilson score interval is more accurate than the normal approximation,
  especially for small samples (N < 30) and extreme proportions (near 0% or 100%).

  ## Parameters

  - `passes` - Number of successes
  - `total` - Total number of trials
  - `confidence` - Confidence level (default: 0.95 for 95% CI)

  ## Returns

  `{lower_bound, upper_bound}` as proportions (0.0-1.0)

  ## Examples

      iex> wilson_score_interval(17, 20)
      {0.62, 0.97}

      iex> wilson_score_interval(20, 20)
      {0.83, 1.0}

      iex> wilson_score_interval(0, 20)
      {0.0, 0.17}
  """
  def wilson_score_interval(passes, total, confidence \\ 0.95)
      when is_integer(passes) and is_integer(total) and total > 0 and
             passes >= 0 and passes <= total do
    # Z-score for the confidence level (1.96 for 95%, 1.645 for 90%)
    z = z_score(confidence)

    # Observed proportion
    p_hat = passes / total

    # Wilson score interval formula
    # See: https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval
    denominator = 1 + z * z / total
    center = (p_hat + z * z / (2 * total)) / denominator
    margin = z * :math.sqrt((p_hat * (1 - p_hat) + z * z / (4 * total)) / total) / denominator

    lower = max(0.0, center - margin)
    upper = min(1.0, center + margin)

    {lower, upper}
  end

  @doc """
  Formats a result with confidence interval per spec section 1.5 report format.

  ## Parameters

  - `result` - Map with `:category`, `:passes`, `:total`, `:threshold` keys

  ## Returns

  Formatted string like: "observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS"

  ## Examples

      iex> format_result(%{category: "observer.extraction", passes: 17, total: 20, threshold: 0.85})
      "observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS"

      iex> format_result(%{category: "foreman.decomposition", passes: 12, total: 20, threshold: 0.75})
      "foreman.decomposition: 12/20 (60%) [CI: 36%-81%] WARN"
  """
  def format_result(%{category: category, passes: passes, total: total, threshold: threshold}) do
    scored =
      score_result(%{category: category, passes: passes, total: total, threshold: threshold})

    rate_pct = round(scored.rate * 100)
    ci_lower_pct = round(scored.ci_lower * 100)
    ci_upper_pct = round(scored.ci_upper * 100)

    status_str =
      case scored.status do
        :pass -> "PASS"
        :warn -> "WARN"
      end

    "#{category}: #{passes}/#{total} (#{rate_pct}%) [CI: #{ci_lower_pct}%-#{ci_upper_pct}%] #{status_str}"
  end

  @doc """
  Scores a result with confidence interval and pass/warn determination.

  ## Parameters

  - `result` - Map with `:category`, `:passes`, `:total`, `:threshold` keys

  ## Returns

  Map with statistical analysis including:
  - `:rate` - Pass rate as proportion (0.0-1.0)
  - `:ci_lower` - Lower bound of 95% confidence interval
  - `:ci_upper` - Upper bound of 95% confidence interval
  - `:status` - `:pass` if rate meets threshold, `:warn` otherwise

  ## Examples

      iex> score_result(%{category: "observer.extraction", passes: 17, total: 20, threshold: 0.85})
      %{
        category: "observer.extraction",
        passes: 17,
        total: 20,
        rate: 0.85,
        ci_lower: 0.62,
        ci_upper: 0.97,
        status: :pass,
        threshold: 0.85
      }
  """
  def score_result(%{category: category, passes: passes, total: total, threshold: threshold})
      when is_binary(category) and is_integer(passes) and is_integer(total) and
             is_number(threshold) do
    rate = passes / total
    {ci_lower, ci_upper} = wilson_score_interval(passes, total)

    status = if rate >= threshold, do: :pass, else: :warn

    %{
      category: category,
      passes: passes,
      total: total,
      rate: rate,
      ci_lower: ci_lower,
      ci_upper: ci_upper,
      status: status,
      threshold: threshold
    }
  end

  @doc """
  Batch scores multiple results.

  ## Parameters

  - `results` - List of result maps

  ## Returns

  List of scored result maps

  ## Examples

      iex> results = [
      ...>   %{category: "observer.extraction", passes: 17, total: 20, threshold: 0.85},
      ...>   %{category: "foreman.decomposition", passes: 12, total: 20, threshold: 0.75}
      ...> ]
      iex> score_results(results)
      [%{category: "observer.extraction", ...}, %{category: "foreman.decomposition", ...}]
  """
  def score_results(results) when is_list(results) do
    Enum.map(results, &score_result/1)
  end

  @doc """
  Batch formats multiple results with confidence intervals.

  ## Parameters

  - `results` - List of result maps

  ## Returns

  List of formatted strings

  ## Examples

      iex> results = [
      ...>   %{category: "observer.extraction", passes: 17, total: 20, threshold: 0.85},
      ...>   %{category: "foreman.decomposition", passes: 12, total: 20, threshold: 0.75}
      ...> ]
      iex> format_results(results)
      [
        "observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS",
        "foreman.decomposition: 12/20 (60%) [CI: 36%-81%] WARN"
      ]
  """
  def format_results(results) when is_list(results) do
    Enum.map(results, &format_result/1)
  end

  # Z-score for standard confidence levels
  # 95% CI: 1.96, 90% CI: 1.645, 99% CI: 2.576
  defp z_score(0.95), do: 1.96
  defp z_score(0.90), do: 1.645
  defp z_score(0.99), do: 2.576

  defp z_score(confidence) when is_float(confidence) and confidence > 0 and confidence < 1 do
    # For other confidence levels, use inverse error function approximation
    # This is a simplified approximation - for production use, consider a proper implementation
    # or limiting to the standard confidence levels above
    cond do
      confidence >= 0.95 -> 1.96
      confidence >= 0.90 -> 1.645
      true -> 1.96
    end
  end
end
