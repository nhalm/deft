defmodule Deft.Eval.RegressionDetection do
  @moduledoc """
  Statistical regression detection for eval results.

  Per spec section 2.3: Uses proportion z-test to detect significant quality regressions
  comparing current run against historical distribution. Separates infrastructure failures
  (deterministic bugs with repeated errors) from model quality regressions (varied errors).
  """

  @type failure :: %{
          fixture: String.t(),
          output: String.t(),
          reason: String.t()
        }

  @doc """
  Detects if current pass rate represents a significant regression vs historical distribution.

  Uses proportion z-test with p < 0.05 one-tailed threshold (z < -1.645).
  Applies Laplace smoothing when pooled rate is at boundaries (0.0 or 1.0).

  ## Parameters
  - current_rate: Pass rate for current run (0.0 to 1.0)
  - current_n: Number of iterations in current run
  - historical_rates: List of pass rates from previous runs

  ## Returns
  - true if significant regression detected (p < 0.05)
  - false if no regression or insufficient history

  ## Examples

      iex> RegressionDetection.significant_regression?(0.60, 20, [0.85, 0.90, 0.88])
      true

      iex> RegressionDetection.significant_regression?(0.85, 20, [0.85, 0.88, 0.82])
      false

      iex> RegressionDetection.significant_regression?(0.85, 20, [])
      false
  """
  @spec significant_regression?(float(), non_neg_integer(), [float()]) :: boolean()
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
          smoothed_pooled = (pooled * n + 0.5) / (n + 1)
          se = :math.sqrt(smoothed_pooled * (1 - smoothed_pooled) / current_n)
          z = (current_rate - smoothed_pooled) / se
          z < -1.645

        true ->
          se = :math.sqrt(pooled * (1 - pooled) / current_n)
          z = (current_rate - pooled) / se
          z < -1.645
      end
    end
  end

  @doc """
  Detects if failures represent an infrastructure bug vs model quality issue.

  Infrastructure failures are deterministic bugs where the same error appears repeatedly.
  Threshold: if 8+ out of 10 failures have the same reason, it's infrastructure.

  ## Parameters
  - failures: List of failure maps with :reason field

  ## Returns
  - {:infrastructure, reason} if deterministic bug detected
  - :model_quality if failures are varied (actual quality regression)
  - :insufficient_data if fewer than 10 failures

  ## Examples

      iex> failures = [
      ...>   %{fixture: "a", output: "x", reason: "timeout"},
      ...>   %{fixture: "b", output: "y", reason: "timeout"},
      ...>   %{fixture: "c", output: "z", reason: "timeout"},
      ...>   %{fixture: "d", output: "w", reason: "timeout"},
      ...>   %{fixture: "e", output: "v", reason: "timeout"},
      ...>   %{fixture: "f", output: "u", reason: "timeout"},
      ...>   %{fixture: "g", output: "t", reason: "timeout"},
      ...>   %{fixture: "h", output: "s", reason: "timeout"},
      ...>   %{fixture: "i", output: "r", reason: "extraction failed"},
      ...>   %{fixture: "j", output: "q", reason: "extraction failed"}
      ...> ]
      iex> RegressionDetection.infrastructure_failure?(failures)
      {:infrastructure, "timeout"}

      iex> failures = [
      ...>   %{fixture: "a", output: "x", reason: "missing field A"},
      ...>   %{fixture: "b", output: "y", reason: "missing field B"},
      ...>   %{fixture: "c", output: "z", reason: "wrong section"},
      ...>   %{fixture: "d", output: "w", reason: "hallucination"},
      ...>   %{fixture: "e", output: "v", reason: "missing field C"},
      ...>   %{fixture: "f", output: "u", reason: "wrong format"},
      ...>   %{fixture: "g", output: "t", reason: "timeout"},
      ...>   %{fixture: "h", output: "s", reason: "incomplete"},
      ...>   %{fixture: "i", output: "r", reason: "wrong priority"},
      ...>   %{fixture: "j", output: "q", reason: "missing context"}
      ...> ]
      iex> RegressionDetection.infrastructure_failure?(failures)
      :model_quality
  """
  @spec infrastructure_failure?([failure()]) ::
          {:infrastructure, String.t()} | :model_quality | :insufficient_data
  def infrastructure_failure?(failures) when length(failures) < 10 do
    :insufficient_data
  end

  def infrastructure_failure?(failures) do
    # Count occurrences of each failure reason
    reason_counts =
      failures
      |> Enum.frequencies_by(& &1.reason)

    # Find the most common reason and its count
    {most_common_reason, max_count} =
      reason_counts
      |> Enum.max_by(fn {_reason, count} -> count end)

    # If same error appears in 8+ out of 10 failures, it's infrastructure
    if max_count >= 8 do
      {:infrastructure, most_common_reason}
    else
      :model_quality
    end
  end

  @doc """
  Analyzes a set of failures to determine if they represent a regression and what type.

  Combines regression detection with infrastructure failure detection to provide
  a complete diagnostic picture.

  ## Parameters
  - current_rate: Pass rate for current run (0.0 to 1.0)
  - current_n: Number of iterations in current run
  - historical_rates: List of pass rates from previous runs
  - failures: List of failure maps from current run

  ## Returns
  A map with analysis results:
  - :is_regression - boolean indicating if statistical regression detected
  - :failure_type - :infrastructure, :model_quality, or :insufficient_data
  - :infrastructure_reason - the repeated error reason if infrastructure failure

  ## Examples

      iex> RegressionDetection.analyze(0.50, 20, [0.85, 0.88], [
      ...>   %{fixture: "a", output: "x", reason: "crash"},
      ...>   %{fixture: "b", output: "y", reason: "crash"},
      ...>   %{fixture: "c", output: "z", reason: "crash"},
      ...>   %{fixture: "d", output: "w", reason: "crash"},
      ...>   %{fixture: "e", output: "v", reason: "crash"},
      ...>   %{fixture: "f", output: "u", reason: "crash"},
      ...>   %{fixture: "g", output: "t", reason: "crash"},
      ...>   %{fixture: "h", output: "s", reason: "crash"},
      ...>   %{fixture: "i", output: "r", reason: "crash"},
      ...>   %{fixture: "j", output: "q", reason: "crash"}
      ...> ])
      %{
        is_regression: true,
        failure_type: :infrastructure,
        infrastructure_reason: "crash"
      }
  """
  @spec analyze(float(), non_neg_integer(), [float()], [failure()]) :: map()
  def analyze(current_rate, current_n, historical_rates, failures) do
    is_regression = significant_regression?(current_rate, current_n, historical_rates)

    case infrastructure_failure?(failures) do
      {:infrastructure, reason} ->
        %{
          is_regression: is_regression,
          failure_type: :infrastructure,
          infrastructure_reason: reason
        }

      failure_type ->
        %{
          is_regression: is_regression,
          failure_type: failure_type,
          infrastructure_reason: nil
        }
    end
  end
end
