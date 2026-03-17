defmodule Deft.Eval.Reflector.CorrectionSurvivalTest do
  use ExUnit.Case, async: false

  alias Deft.{Config, Provider}
  alias Deft.OM.Reflector

  @moduletag :eval
  @moduletag :expensive

  @fixture_path "test/eval/fixtures/observation_sets/correction_markers.txt"
  @target_size 20_000
  @calibration_factor 4.0

  setup_all do
    # Register Anthropic provider for LLM calls
    :ok = Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
    :ok
  end

  describe "Reflector CORRECTION marker survival" do
    @tag timeout: 300_000
    test "preserves all CORRECTION markers through compression" do
      # Load fixture
      observations = File.read!(@fixture_path)

      # Extract all CORRECTION markers from input
      correction_markers = extract_correction_markers(observations)

      # Verify fixture contains exactly 3 CORRECTION markers
      assert length(correction_markers) == 3,
             "Fixture must contain exactly 3 CORRECTION markers, found #{length(correction_markers)}"

      # Create config
      config = %Config{
        model: "claude-sonnet-4.5",
        provider: "anthropic",
        om_reflector_model: "claude-haiku-4.5",
        turn_limit: 100,
        tool_timeout: 120_000,
        bash_timeout: 120_000,
        om_enabled: true,
        om_observer_model: "claude-haiku-4.5",
        cache_token_threshold: 10_000,
        cache_token_threshold_read: 20_000,
        cache_token_threshold_grep: 8_000,
        cache_token_threshold_ls: 4_000,
        cache_token_threshold_find: 4_000,
        issues_compaction_days: 90
      }

      # Run Reflector (single iteration - this is a hard assertion)
      IO.puts("\n[Running Reflector CORRECTION survival test]")
      result = Reflector.run(config, observations, @target_size, @calibration_factor)

      IO.puts(
        "  Compressed: #{result.before_tokens} → #{result.after_tokens} tokens (level #{result.compression_level})"
      )

      # Extract CORRECTION markers from output
      output_correction_markers = extract_correction_markers(result.compressed_observations)

      # Check which markers survived
      missing_markers =
        Enum.reject(correction_markers, fn marker ->
          String.contains?(result.compressed_observations, marker)
        end)

      all_survived = missing_markers == []

      # Report results
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Reflector CORRECTION Marker Survival Eval")
      IO.puts(String.duplicate("=", 70))

      IO.puts(
        "CORRECTION markers preserved: #{length(output_correction_markers)}/#{length(correction_markers)}"
      )

      if missing_markers == [] do
        IO.puts("Status: ✓ PASS")
        IO.puts("\nAll CORRECTION markers survived compression:")

        Enum.each(correction_markers, fn marker ->
          IO.puts("  ✓ #{String.slice(marker, 0..80)}...")
        end)
      else
        IO.puts("Status: ✗ FAIL")
        IO.puts("\nMissing CORRECTION markers:")

        Enum.each(missing_markers, fn marker ->
          IO.puts("  ✗ #{marker}")
        end)

        IO.puts("\nMarkers found in output:")

        Enum.each(output_correction_markers, fn marker ->
          IO.puts("  ✓ #{String.slice(marker, 0..80)}...")
        end)
      end

      IO.puts(String.duplicate("=", 70))

      # Hard assertion (this is a prompt bug if it fails)
      assert all_survived,
             """
             Reflector CORRECTION survival eval failed: Not all CORRECTION markers survived compression.

             This is a HARD ASSERTION failure. If this fails, it's a prompt bug — fix the prompt.
             The Reflector MUST preserve ALL CORRECTION markers through compression.

             Expected markers (#{length(correction_markers)}):
             #{Enum.map_join(correction_markers, "\n", &"  - #{&1}")}

             Missing markers (#{length(missing_markers)}):
             #{Enum.map_join(missing_markers, "\n", &"  - #{&1}")}

             Found in output (#{length(output_correction_markers)}):
             #{Enum.map_join(output_correction_markers, "\n", &"  - #{&1}")}
             """
    end
  end

  # Helper function to extract CORRECTION markers from observation text
  defp extract_correction_markers(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line -> String.contains?(line, "CORRECTION:") end)
    |> Enum.map(&String.trim/1)
  end
end
