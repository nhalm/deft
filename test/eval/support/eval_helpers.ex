defmodule Eval.Support.EvalHelpers do
  @moduledoc """
  Helper functions for eval tests.
  Provides utilities for loading fixtures, running iterations, and computing confidence intervals.
  """

  # Spec: specs/testing/evals/README.md §1.3-1.7

  @doc """
  Loads a fixture from the fixtures directory.
  """
  def load_fixture(_path) do
    # TODO: Implement fixture loading from test/eval/fixtures/
    # - Read JSON fixture files
    # - Validate spec_version
    # - Return structured fixture data
    {:error, :not_implemented}
  end

  @doc """
  Runs an eval over N iterations and returns pass rate with confidence interval.
  """
  def run_iterations(_test_fn, _iterations \\ 20) do
    # TODO: Implement iteration runner
    # - Run test_fn N times
    # - Count passes/failures
    # - Compute binomial confidence interval (Wilson score interval)
    # - Return {pass_count, total, pass_rate, ci_lower, ci_upper}
    {:error, :not_implemented}
  end

  @doc """
  Computes Wilson score confidence interval for a proportion.
  """
  def confidence_interval(_successes, _trials, _confidence_level \\ 0.95) do
    # TODO: Implement Wilson score interval
    # Used for computing CI on pass rates
    # Returns {lower_bound, upper_bound}
    {:error, :not_implemented}
  end

  @doc """
  Loads holdout fixtures (never used during prompt development).
  """
  def load_holdout_fixtures(_category) do
    # TODO: Implement holdout fixture loading
    # - Load from test/eval/fixtures/holdout/
    # - 20-30% of total fixtures
    {:error, :not_implemented}
  end
end
