defmodule Deft.Eval.Reflector.CompressionTest do
  use ExUnit.Case, async: false

  alias Deft.OM.Reflector
  alias Deft.EvalHelpers

  @moduletag :eval
  @moduletag :expensive

  # Calibration factor for token estimation (4.0 is default)
  @calibration_factor 4.0

  # Target size for compression (20k tokens as per spec)
  @target_size 20_000

  # Number of iterations for statistical tests
  @iterations 20

  # Pass rate threshold for compression (80% as per work item)
  @compression_pass_rate 0.80

  describe "compression target" do
    @tag timeout: 600_000
    test "compresses observations to target size (20 iterations, 80% pass rate)" do
      fixture_path = "test/eval/fixtures/observation_sets/large_observations.txt"
      observations = File.read!(fixture_path)

      config = EvalHelpers.test_config()

      # Run compression 20 times
      results =
        for _i <- 1..@iterations do
          result = Reflector.run(config, observations, @target_size, @calibration_factor)

          # Check if compressed output meets target
          passes = result.after_tokens <= @target_size
          {passes, result}
        end

      # Calculate pass rate
      passes = Enum.count(results, fn {passed, _result} -> passed end)
      pass_rate = passes / @iterations

      # Log results
      IO.puts("\nCompression Test Results:")
      IO.puts("Passes: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")

      results
      |> Enum.with_index(1)
      |> Enum.each(fn {{passed, result}, idx} ->
        status = if passed, do: "✓", else: "✗"

        IO.puts(
          "  [#{idx}] #{status} #{result.before_tokens} → #{result.after_tokens} tokens (level #{result.compression_level}, #{result.llm_calls} calls)"
        )
      end)

      # Assert pass rate meets threshold
      assert pass_rate >= @compression_pass_rate,
             "Compression pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{@compression_pass_rate * 100}%"
    end
  end

  describe "section structure preservation" do
    @tag timeout: 180_000
    test "preserves all 5 standard section headers (hard assertion)" do
      fixture_path = "test/eval/fixtures/observation_sets/large_observations.txt"
      observations = File.read!(fixture_path)

      config = EvalHelpers.test_config()

      # Run compression once
      result = Reflector.run(config, observations, @target_size, @calibration_factor)

      compressed = result.compressed_observations

      # All 5 standard sections must be present
      required_sections = [
        "## Current State",
        "## User Preferences",
        "## Files & Architecture",
        "## Decisions",
        "## Session History"
      ]

      missing_sections =
        Enum.reject(required_sections, fn section ->
          String.contains?(compressed, section)
        end)

      # Hard assertion - all sections must be present
      assert Enum.empty?(missing_sections),
             "Missing required sections after compression: #{inspect(missing_sections)}"

      # Verify sections are in correct order
      section_positions =
        Enum.map(required_sections, fn section ->
          case :binary.match(compressed, section) do
            {pos, _len} -> {section, pos}
            :nomatch -> {section, nil}
          end
        end)

      positions = Enum.map(section_positions, fn {_section, pos} -> pos end)

      # Check that positions are in ascending order (nil would have failed above)
      assert positions == Enum.sort(positions),
             "Sections are not in canonical order. Found: #{inspect(section_positions)}"
    end
  end
end
