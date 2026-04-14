defmodule Eval.Spilling.ThresholdCalibrationTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/spilling.md
  # Validates that spilling thresholds are correctly calibrated per tool

  @moduledoc """
  Threshold calibration evaluation for spilling.
  Tests that per-tool spilling thresholds are appropriate for content types.
  """

  # TODO: Implement threshold calibration tests
  # - Grid search over threshold values
  # - Measure recall (no lost info) vs token savings
  # - Pass rate: calibration-based (see spec)

  @tag :skip
  test "placeholder for threshold calibration" do
    # Implement using Tribunal assertions and grid search
    # See specs/testing/evals/spilling.md
    :ok
  end
end
