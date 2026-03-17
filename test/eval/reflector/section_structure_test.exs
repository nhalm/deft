defmodule Deft.Eval.Reflector.SectionStructureTest do
  use ExUnit.Case, async: false

  alias Deft.{Config, Provider}
  alias Deft.OM.Reflector

  @moduletag :eval
  @moduletag :expensive

  @fixture_path "test/eval/fixtures/observation_sets/mixed_priority_items.txt"
  @target_size 20_000
  @calibration_factor 4.0

  # The 5 standard sections in canonical order
  @sections [
    "## Current State",
    "## User Preferences",
    "## Files & Architecture",
    "## Decisions",
    "## Session History"
  ]

  setup_all do
    # Register Anthropic provider for LLM calls
    :ok = Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
    :ok
  end

  describe "Reflector section structure preservation" do
    @tag timeout: 300_000
    test "preserves all 5 section headers in canonical order" do
      # Load fixture
      observations = File.read!(@fixture_path)

      # Verify fixture contains all 5 sections
      missing_sections =
        Enum.reject(@sections, fn section ->
          String.contains?(observations, section)
        end)

      assert missing_sections == [],
             "Fixture must contain all 5 sections. Missing: #{inspect(missing_sections)}"

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

      # Run Reflector
      IO.puts("\n[Running Reflector section structure test]")
      result = Reflector.run(config, observations, @target_size, @calibration_factor)

      IO.puts(
        "  Compressed: #{result.before_tokens} → #{result.after_tokens} tokens (level #{result.compression_level})"
      )

      # Check that all 5 sections are present in output
      missing_in_output =
        Enum.reject(@sections, fn section ->
          String.contains?(result.compressed_observations, section)
        end)

      # Check section order by finding positions
      section_positions =
        Enum.map(@sections, fn section ->
          case :binary.match(result.compressed_observations, section) do
            {pos, _len} -> {section, pos}
            :nomatch -> {section, nil}
          end
        end)

      # Filter out sections that weren't found
      found_sections =
        section_positions
        |> Enum.reject(fn {_section, pos} -> is_nil(pos) end)

      # Check if sections are in order (positions should be ascending)
      positions_in_order? =
        found_sections
        |> Enum.map(fn {_section, pos} -> pos end)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [a, b] -> a < b end)

      # Report results
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Reflector Section Structure Preservation Eval")
      IO.puts(String.duplicate("=", 70))
      IO.puts("All sections present: #{missing_in_output == []}")
      IO.puts("Sections in order: #{positions_in_order?}")

      if missing_in_output != [] do
        IO.puts("\nMissing sections:")

        Enum.each(missing_in_output, fn section ->
          IO.puts("  - #{section}")
        end)
      end

      if found_sections != [] and not positions_in_order? do
        IO.puts("\nSection order:")

        Enum.each(section_positions, fn {section, pos} ->
          if pos do
            IO.puts("  #{section}: position #{pos}")
          else
            IO.puts("  #{section}: NOT FOUND")
          end
        end)
      end

      if missing_in_output == [] and positions_in_order? do
        IO.puts("Status: ✓ PASS")
      else
        IO.puts("Status: ✗ FAIL")
      end

      IO.puts(String.duplicate("=", 70))

      # Hard assertions (this is a prompt bug if it fails, not a statistical issue)
      assert missing_in_output == [],
             """
             Reflector section structure eval failed: Not all sections present in output.
             Missing sections: #{inspect(missing_in_output)}

             This is a HARD ASSERTION failure. If this fails, it's a prompt bug — fix the prompt.
             The Reflector MUST preserve all 5 section headers.

             Expected sections (in order):
             #{Enum.map_join(@sections, "\n", &"  - #{&1}")}
             """

      assert positions_in_order?,
             """
             Reflector section structure eval failed: Sections not in canonical order.

             This is a HARD ASSERTION failure. If this fails, it's a prompt bug — fix the prompt.
             The Reflector MUST NOT reorder sections.

             Expected order:
             #{Enum.map_join(@sections, "\n", &"  - #{&1}")}

             Found positions:
             #{Enum.map_join(section_positions, "\n", fn {section, pos} -> "  #{section}: #{pos || "NOT FOUND"}" end)}
             """
    end
  end
end
