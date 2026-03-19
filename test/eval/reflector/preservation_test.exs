defmodule Deft.Eval.Reflector.PreservationTest do
  use ExUnit.Case, async: false

  alias Deft.OM.Reflector
  alias Deft.EvalHelpers

  @moduletag :eval
  @moduletag :expensive

  # Calibration factor for token estimation
  @calibration_factor 4.0

  # Target size for compression
  @target_size 20_000

  # Number of iterations for statistical tests
  @iterations 20

  # Pass rate threshold for high-priority preservation (95% as per spec)
  @preservation_pass_rate 0.95

  describe "high-priority preservation" do
    @tag timeout: 600_000
    test "preserves all 🔴 items during compression (20 iterations, 95% pass rate)" do
      fixture_path = "test/eval/fixtures/observation_sets/priority_mixed.txt"
      observations = File.read!(fixture_path)

      config = EvalHelpers.test_config()

      # Extract all 🔴 (red) items from original observations
      red_items = extract_red_items(observations)

      assert length(red_items) >= 10,
             "Fixture should contain at least 10 🔴 items, found #{length(red_items)}"

      # Run compression 20 times
      results =
        for _i <- 1..@iterations do
          result = Reflector.run(config, observations, @target_size, @calibration_factor)

          compressed = result.compressed_observations

          # Check how many red items survived
          survived =
            Enum.count(red_items, fn item ->
              # Extract the core content (without timestamp and marker)
              content = extract_item_content(item)
              String.contains?(compressed, content)
            end)

          survival_rate = survived / length(red_items)
          passes = survival_rate == 1.0

          {passes, survival_rate, survived, result}
        end

      # Calculate pass rate (how many iterations had 100% red item survival)
      passes = Enum.count(results, fn {passed, _rate, _survived, _result} -> passed end)
      pass_rate = passes / @iterations

      # Log results
      IO.puts("\nHigh-Priority Preservation Test Results:")
      IO.puts("Total 🔴 items: #{length(red_items)}")

      IO.puts(
        "Iterations with 100% survival: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      results
      |> Enum.with_index(1)
      |> Enum.each(fn {{passed, survival_rate, survived, _result}, idx} ->
        status = if passed, do: "✓", else: "✗"

        IO.puts(
          "  [#{idx}] #{status} #{survived}/#{length(red_items)} survived (#{Float.round(survival_rate * 100, 1)}%)"
        )
      end)

      # Assert pass rate meets threshold
      assert pass_rate >= @preservation_pass_rate,
             "Preservation pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{@preservation_pass_rate * 100}%"
    end
  end

  describe "CORRECTION marker survival" do
    @tag timeout: 180_000
    test "preserves all CORRECTION markers during compression (hard assertion)" do
      fixture_path = "test/eval/fixtures/observation_sets/with_corrections.txt"
      observations = File.read!(fixture_path)

      config = EvalHelpers.test_config()

      # Extract all CORRECTION markers from original observations
      correction_markers = extract_correction_markers(observations)

      assert length(correction_markers) >= 3,
             "Fixture should contain at least 3 CORRECTION markers, found #{length(correction_markers)}"

      # Run compression once (hard assertion test)
      result = Reflector.run(config, observations, @target_size, @calibration_factor)

      compressed = result.compressed_observations

      # Check that all CORRECTION markers survived
      missing_markers =
        Enum.reject(correction_markers, fn marker ->
          String.contains?(compressed, marker)
        end)

      # Hard assertion - all CORRECTION markers must survive
      assert Enum.empty?(missing_markers),
             "Missing CORRECTION markers after compression: #{inspect(missing_markers)}"

      IO.puts("\nCORRECTION Marker Survival Test:")
      IO.puts("All #{length(correction_markers)} CORRECTION markers preserved ✓")
    end
  end

  # Helper functions

  defp extract_red_items(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "🔴"))
    |> Enum.map(&String.trim/1)
  end

  defp extract_item_content(item) do
    # Remove timestamp like (14:32) and emoji, extract core content
    item
    |> String.replace(~r/\([\d:]+\)\s*/, "")
    |> String.replace("🔴", "")
    |> String.replace("🟡", "")
    |> String.trim()
  end

  defp extract_correction_markers(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "CORRECTION:"))
    |> Enum.map(&String.trim/1)
  end
end
