defmodule Deft.Eval.Helpers do
  @moduledoc """
  Helper functions for eval test infrastructure.

  Provides statistical utilities like confidence interval calculations.
  """

  @doc """
  Computes Wilson score confidence interval for a binomial proportion.

  Returns {lower, upper} bounds for a 95% confidence interval.

  The Wilson score interval is more accurate than the normal approximation,
  especially for small sample sizes or extreme probabilities.

  ## Examples

      iex> Deft.Eval.Helpers.confidence_interval(17, 20)
      {0.62, 0.97}  # approximately

      iex> Deft.Eval.Helpers.confidence_interval(0, 10)
      {0.0, 0.31}  # approximately

  ## References

  - Wilson, E. B. (1927). "Probable inference, the law of succession, and statistical inference".
    Journal of the American Statistical Association.
  """
  def confidence_interval(successes, total) when total > 0 do
    # Wilson score confidence interval
    # z = 1.96 for 95% confidence
    z = 1.96
    p_hat = successes / total
    z_squared = z * z

    # Center of interval
    center = (p_hat + z_squared / (2 * total)) / (1 + z_squared / total)

    # Margin of error
    margin =
      z * :math.sqrt(p_hat * (1 - p_hat) / total + z_squared / (4 * total * total)) /
        (1 + z_squared / total)

    lower = max(0.0, center - margin)
    upper = min(1.0, center + margin)

    {lower, upper}
  end

  def confidence_interval(_successes, 0) do
    # Edge case: no trials
    {0.0, 1.0}
  end
end
