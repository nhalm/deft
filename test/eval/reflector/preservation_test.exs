defmodule Deft.Eval.Reflector.PreservationTest do
  @moduledoc """
  Eval tests for Reflector preservation properties.

  Tests that the Reflector:
  1. Preserves high-priority (🔴) items during compression (95% over 20 iterations)
  2. Preserves section structure in canonical order (hard assertion, 100%)
  3. Preserves CORRECTION markers (hard assertion, 100%)
  """

  use ExUnit.Case, async: false

  alias Deft.Config
  alias Deft.Eval.Scoring
  alias Deft.OM.Reflector

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @high_priority_threshold 0.95
  @target_size 20_000

  # Standard section order per observational-memory spec
  @standard_sections [
    "Current State",
    "User Preferences",
    "Files & Architecture",
    "Decisions",
    "Session History"
  ]

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "high-priority preservation - 95% over 20 iterations" do
    @tag timeout: 300_000
    test "preserves all 🔴 items during compression", %{config: config} do
      # Generate observations with 10 🔴 items, 30 🟡 items, 20 unlabeled
      observations_with_markers = generate_priority_observations()

      # Extract the red markers for validation
      red_markers = extract_red_markers(observations_with_markers)

      IO.puts("\nTesting preservation of #{length(red_markers)} 🔴 items...")

      results =
        Enum.map(1..@iterations, fn i ->
          IO.write(".")

          # Run Reflector compression
          result = Reflector.run(config, observations_with_markers, @target_size, 4.0)
          compressed = result.compressed_observations

          # Judge: Are all red markers present?
          all_preserved =
            Enum.all?(red_markers, fn marker ->
              String.contains?(compressed, marker)
            end)

          if not all_preserved do
            missing = Enum.reject(red_markers, &String.contains?(compressed, &1))

            IO.puts(
              "\n  Iteration #{i} failed: #{length(missing)}/#{length(red_markers)} red items missing"
            )
          end

          all_preserved
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\n\nHigh-priority preservation: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      # Report with confidence interval
      result_data = %{
        category: "reflector.high_priority_preservation",
        passes: pass_count,
        total: @iterations,
        threshold: @high_priority_threshold
      }

      formatted = Scoring.format_result(result_data)
      IO.puts("#{formatted}")

      assert pass_rate >= @high_priority_threshold,
             "High-priority preservation below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@high_priority_threshold * 100}%"
    end
  end

  describe "section structure preservation - hard assertion (100%)" do
    @tag timeout: 180_000
    test "preserves all 5 section headers in canonical order", %{config: config} do
      # Generate observations with all 5 standard sections
      observations = generate_all_sections()

      # Run Reflector compression ONCE (hard assertion, not statistical)
      result = Reflector.run(config, observations, @target_size, 4.0)
      compressed = result.compressed_observations

      IO.puts("\n\nSection structure preservation test:")

      # Check that all sections are present
      missing_sections =
        Enum.reject(@standard_sections, fn section ->
          String.contains?(compressed, "## #{section}")
        end)

      if missing_sections != [] do
        IO.puts("  ❌ Missing sections: #{inspect(missing_sections)}")
      else
        IO.puts("  ✓ All 5 sections present")
      end

      assert missing_sections == [],
             "Missing sections: #{inspect(missing_sections)}"

      # Check that sections are in canonical order
      section_order = extract_section_order(compressed)

      expected_order =
        Enum.filter(@standard_sections, fn section ->
          String.contains?(compressed, "## #{section}")
        end)

      if section_order != expected_order do
        IO.puts("  ❌ Section order incorrect")
        IO.puts("     Expected: #{inspect(expected_order)}")
        IO.puts("     Got:      #{inspect(section_order)}")
      else
        IO.puts("  ✓ Sections in canonical order")
      end

      assert section_order == expected_order,
             "Sections not in canonical order. Expected: #{inspect(expected_order)}, Got: #{inspect(section_order)}"
    end
  end

  describe "CORRECTION marker survival - hard assertion (100%)" do
    @tag timeout: 180_000
    test "preserves all CORRECTION markers during compression", %{config: config} do
      # Generate observations with 3 CORRECTION markers
      observations = generate_observations_with_corrections()

      # Extract CORRECTION markers for validation
      correction_markers = extract_correction_markers(observations)

      IO.puts("\n\nCORRECTION marker survival test:")
      IO.puts("  Testing #{length(correction_markers)} CORRECTION markers...")

      # Run Reflector compression ONCE (hard assertion, not statistical)
      result = Reflector.run(config, observations, @target_size, 4.0)
      compressed = result.compressed_observations

      # Check that all CORRECTION markers survived
      missing_markers =
        Enum.reject(correction_markers, fn marker ->
          String.contains?(compressed, marker)
        end)

      if missing_markers != [] do
        IO.puts("  ❌ Missing CORRECTION markers: #{length(missing_markers)}")

        Enum.each(missing_markers, fn marker ->
          IO.puts("     - #{String.slice(marker, 0..80)}...")
        end)
      else
        IO.puts("  ✓ All CORRECTION markers preserved")
      end

      assert missing_markers == [],
             "CORRECTION markers missing: #{length(missing_markers)}"
    end
  end

  # Helper: Generate observations with mixed priority levels
  defp generate_priority_observations do
    red_items = [
      "- (14:00) 🔴 User stated they are building Deft, an Elixir coding agent",
      "- (14:05) 🔴 User prefers comprehensive test coverage with AI evals",
      "- (14:10) 🔴 User wants spec-driven development workflow",
      "- (14:15) 🔴 User follows OTP supervision patterns strictly",
      "- (14:20) 🔴 User explicitly chose Elixir over Go for this project",
      "- (14:25) 🔴 User prefers functional programming over OOP",
      "- (14:30) 🔴 User wants observational memory as core differentiator",
      "- (14:35) 🔴 User specified Tribunal for eval framework",
      "- (14:40) 🔴 User decided against vector embeddings for memory",
      "- (14:45) 🔴 User requires 95% pass rate for safety evals"
    ]

    yellow_items =
      Enum.map(1..30, fn i ->
        "- (15:#{String.pad_leading(Integer.to_string(rem(i, 60)), 2, "0")}) 🟡 Read lib/deft/module_#{i}.ex — contains implementation detail #{i}"
      end)

    unlabeled_items =
      Enum.map(1..20, fn i ->
        "- (16:#{String.pad_leading(Integer.to_string(rem(i, 60)), 2, "0")}) Completed minor task #{i} without priority marker"
      end)

    """
    ## Current State
    - (16:30) Active task: testing Reflector preservation
    - (16:30) Last action: generated priority observations

    ## User Preferences
    #{Enum.join(Enum.take(red_items, 5), "\n")}

    ## Files & Architecture
    #{Enum.join(Enum.take(yellow_items, 15), "\n")}

    ## Decisions
    #{Enum.join(Enum.drop(red_items, 5), "\n")}

    ## Session History
    #{Enum.join(Enum.drop(yellow_items, 15), "\n")}
    #{Enum.join(unlabeled_items, "\n")}
    """
  end

  # Helper: Extract red (🔴) marker content for verification
  defp extract_red_markers(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "🔴"))
    |> Enum.map(&String.trim/1)
    # Extract the meaningful part (after the emoji)
    |> Enum.map(fn line ->
      # Get the text after the emoji, which is the unique content
      case String.split(line, "🔴 ", parts: 2) do
        [_, content] -> content
        _ -> line
      end
    end)
  end

  # Helper: Generate observations with all 5 standard sections
  defp generate_all_sections do
    """
    ## Current State
    - (14:00) Active task: testing section preservation
    - (14:00) Last action: generated all sections
    - (14:00) Blocking error: none

    ## User Preferences
    - (13:00) 🔴 User prefers Elixir for backend development
    - (13:05) 🔴 User wants comprehensive AI evals
    #{Enum.map_join(1..15, "\n", fn i -> "- (13:#{10 + i}) 🟡 Preference detail #{i}" end)}

    ## Files & Architecture
    - (12:00) 🟡 Read lib/deft/om/reflector.ex — compression with escalating levels
    - (12:05) 🟡 Read lib/deft/om/observer.ex — observation extraction
    #{Enum.map_join(1..25, "\n", fn i -> "- (12:#{10 + i}) 🟡 Architecture detail #{i}" end)}

    ## Decisions
    - (11:00) 🟡 Chose Task-based Observer/Reflector over GenServer
    - (11:05) 🟡 Chose async buffering for observation pre-computation
    #{Enum.map_join(1..20, "\n", fn i -> "- (11:#{10 + i}) 🟡 Decision detail #{i}" end)}

    ## Session History
    - (10:00) 🔴 User started Deft project for autonomous coding agent
    - (10:05) 🟡 Completed harness specification
    #{Enum.map_join(1..50, "\n", fn i -> "- (10:#{10 + i}) 🟡 History item #{i}" end)}
    """
  end

  # Helper: Extract section order from compressed observations
  defp extract_section_order(compressed) do
    @standard_sections
    |> Enum.filter(fn section ->
      String.contains?(compressed, "## #{section}")
    end)
    |> Enum.sort_by(fn section ->
      # Find the position of each section header
      case :binary.match(compressed, "## #{section}") do
        {pos, _} -> pos
        :nomatch -> 999_999
      end
    end)
  end

  # Helper: Generate observations with CORRECTION markers
  defp generate_observations_with_corrections do
    """
    ## Current State
    - (14:00) Active task: testing CORRECTION marker preservation
    - (14:00) Last action: added CORRECTION markers

    ## User Preferences
    - (13:00) 🔴 User prefers Elixir for all services
    - (13:05) CORRECTION: User actually uses mix of Elixir and Go — Elixir for agent logic, Go for CLI
    #{Enum.map_join(1..10, "\n", fn i -> "- (13:#{10 + i}) 🟡 Preference #{i}" end)}

    ## Files & Architecture
    - (12:00) 🟡 Read lib/deft/om/reflector.ex
    - (12:05) CORRECTION: Reflector uses escalating compression levels 0-3, not binary on/off
    #{Enum.map_join(1..15, "\n", fn i -> "- (12:#{10 + i}) 🟡 File detail #{i}" end)}

    ## Decisions
    - (11:00) 🟡 Chose Breeze for TUI
    - (11:05) CORRECTION: Evaluated Breeze and Termite, chose Breeze for LiveView-style API
    #{Enum.map_join(1..12, "\n", fn i -> "- (11:#{10 + i}) 🟡 Decision #{i}" end)}

    ## Session History
    - (10:00) 🔴 User started Deft project
    #{Enum.map_join(1..30, "\n", fn i -> "- (10:#{10 + i}) 🟡 History #{i}" end)}
    """
  end

  # Helper: Extract CORRECTION markers
  defp extract_correction_markers(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "CORRECTION:"))
    |> Enum.map(&String.trim/1)
  end
end
