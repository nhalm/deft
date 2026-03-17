defmodule Deft.Eval.RegressionDetectionTest do
  use ExUnit.Case, async: true
  alias Deft.Eval.RegressionDetection

  doctest RegressionDetection

  describe "significant_regression?/3" do
    test "detects significant regression when current rate drops substantially" do
      # 60% vs historical 85-90% should be regression
      assert RegressionDetection.significant_regression?(0.60, 20, [0.85, 0.90, 0.88])
    end

    test "does not flag regression when rate is within normal variance" do
      # 85% vs historical 82-88% is normal variance
      refute RegressionDetection.significant_regression?(0.85, 20, [0.85, 0.88, 0.82])
    end

    test "returns false when no historical data exists" do
      refute RegressionDetection.significant_regression?(0.50, 20, [])
    end

    test "handles pooled rate at 0.0 boundary with Laplace smoothing" do
      # All historical rates are 0.0 - should apply Laplace smoothing
      result = RegressionDetection.significant_regression?(0.0, 20, [0.0, 0.0, 0.0])
      # Should not crash, returns boolean
      assert is_boolean(result)
    end

    test "handles pooled rate at 1.0 boundary with Laplace smoothing" do
      # All historical rates are 1.0 - should apply Laplace smoothing
      result = RegressionDetection.significant_regression?(1.0, 20, [1.0, 1.0, 1.0])
      # Should not crash, returns boolean
      assert is_boolean(result)
    end

    test "detects regression from perfect scores to lower scores" do
      # Drop from 100% to 60% should be detected with smoothing
      assert RegressionDetection.significant_regression?(0.60, 20, [1.0, 1.0, 1.0])
    end
  end

  describe "infrastructure_failure?/1" do
    test "detects infrastructure failure when same error appears 8+ times out of 10" do
      failures =
        Enum.map(1..8, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "timeout"}
        end) ++
          [
            %{fixture: "fixture-9", output: "output", reason: "different error"},
            %{fixture: "fixture-10", output: "output", reason: "another error"}
          ]

      assert {:infrastructure, "timeout"} = RegressionDetection.infrastructure_failure?(failures)
    end

    test "identifies model quality issue when errors are varied" do
      failures =
        Enum.map(1..10, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "error-#{i}"}
        end)

      assert :model_quality = RegressionDetection.infrastructure_failure?(failures)
    end

    test "returns insufficient_data when fewer than 10 failures" do
      failures = [
        %{fixture: "fixture-1", output: "output", reason: "timeout"},
        %{fixture: "fixture-2", output: "output", reason: "timeout"}
      ]

      assert :insufficient_data = RegressionDetection.infrastructure_failure?(failures)
    end

    test "edge case: exactly 8 same errors out of 10 is infrastructure" do
      failures =
        Enum.map(1..8, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "crash"}
        end) ++
          [
            %{fixture: "fixture-9", output: "output", reason: "different"},
            %{fixture: "fixture-10", output: "output", reason: "another"}
          ]

      assert {:infrastructure, "crash"} = RegressionDetection.infrastructure_failure?(failures)
    end

    test "edge case: 7 same errors out of 10 is model quality" do
      failures =
        Enum.map(1..7, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "extraction failed"}
        end) ++
          [
            %{fixture: "fixture-8", output: "output", reason: "different"},
            %{fixture: "fixture-9", output: "output", reason: "another"},
            %{fixture: "fixture-10", output: "output", reason: "third"}
          ]

      assert :model_quality = RegressionDetection.infrastructure_failure?(failures)
    end
  end

  describe "analyze/4" do
    test "combines regression detection with infrastructure failure detection" do
      failures =
        Enum.map(1..10, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "crash"}
        end)

      result = RegressionDetection.analyze(0.50, 20, [0.85, 0.88], failures)

      assert result.is_regression == true
      assert result.failure_type == :infrastructure
      assert result.infrastructure_reason == "crash"
    end

    test "identifies model quality regression" do
      failures =
        Enum.map(1..10, fn i ->
          %{fixture: "fixture-#{i}", output: "output", reason: "error-#{i}"}
        end)

      result = RegressionDetection.analyze(0.60, 20, [0.85, 0.88], failures)

      assert result.is_regression == true
      assert result.failure_type == :model_quality
      assert result.infrastructure_reason == nil
    end

    test "handles no regression with insufficient failure data" do
      failures = [
        %{fixture: "fixture-1", output: "output", reason: "timeout"}
      ]

      result = RegressionDetection.analyze(0.85, 20, [0.85, 0.88], failures)

      assert result.is_regression == false
      assert result.failure_type == :insufficient_data
      assert result.infrastructure_reason == nil
    end
  end
end
