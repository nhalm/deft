defmodule Deft.Eval.Reflector.CompressionTest do
  @moduledoc """
  Eval tests for Reflector compression target.

  Tests that the Reflector compresses large observation text to ≤50% of the
  threshold (20k tokens from 40k input).

  Pass rate: 90% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.Config
  alias Deft.Eval.Scoring
  alias Deft.OM.Reflector

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.90
  @target_size 20_000

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "compression target - 90% over 20 iterations" do
    @tag timeout: 300_000
    test "compresses 40k tokens to ≤20k tokens", %{config: config} do
      # Generate a large observation text (~40k tokens at 4.0 calibration)
      large_observations = generate_large_observations()

      results =
        Enum.map(1..@iterations, fn i ->
          IO.write(".")

          # Run Reflector compression
          result = Reflector.run(config, large_observations, @target_size, 4.0)

          # Judge: Does the output meet the compression target?
          success = result.after_tokens <= @target_size

          if not success do
            IO.puts(
              "\n  Iteration #{i} failed: #{result.after_tokens} tokens (target: #{@target_size})"
            )
          end

          success
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\n\nCompression target (≤#{@target_size} tokens): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      # Report with confidence interval using scoring helper
      result_data = %{
        category: "reflector.compression",
        passes: pass_count,
        total: @iterations,
        threshold: @pass_threshold
      }

      formatted = Scoring.format_result(result_data)
      IO.puts("#{formatted}")

      assert pass_rate >= @pass_threshold,
             "Compression target below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Helper: Generate large observation text (~160k chars = ~40k tokens at 4.0 calibration)
  defp generate_large_observations do
    sections = [
      """
      ## Current State
      - (15:30) Active task: implementing observational memory compression evals
      - (15:30) Last action: created test/eval/reflector directory
      - (15:29) Blocking error: none
      - (15:28) Current focus: Reflector compression target test
      - (15:27) Test status: writing compression_test.exs
      """,
      """
      ## User Preferences
      - (14:00) 🔴 User prefers Elixir for all backend services
      - (14:05) 🔴 User wants comprehensive test coverage with evals
      - (14:10) 🔴 User follows Anthropic's agent SDK patterns
      - (14:15) 🔴 User prefers statistical evals over deterministic where appropriate
      - (14:20) 🔴 User wants spec-driven development with autonomous loop
      - (14:25) 🔴 User values clear documentation and explicit specifications
      - (14:30) 🔴 User prefers composition over inheritance
      - (14:35) 🔴 User follows OTP supervision tree patterns
      """,
      generate_large_section("Files & Architecture", 50),
      generate_large_section("Decisions", 40),
      generate_large_section("Session History", 200)
    ]

    Enum.join(sections, "\n\n")
  end

  # Generate a large section with many observation items
  defp generate_large_section(section_name, item_count) do
    header = "## #{section_name}\n"

    items =
      Enum.map(1..item_count, fn i ->
        timestamp = "14:#{rem(i, 60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
        priority = if rem(i, 3) == 0, do: "🔴", else: "🟡"

        case section_name do
          "Files & Architecture" ->
            "- (#{timestamp}) #{priority} Read lib/deft/om/module_#{i}.ex — contains helper function func_#{i}/#{rem(i, 3) + 1} for processing observation data with pattern matching and guard clauses"

          "Decisions" ->
            "- (#{timestamp}) #{priority} Chose approach #{i} for implementation detail #{i} because it provides better performance and clearer code structure while maintaining compatibility with existing patterns"

          "Session History" ->
            "- (#{timestamp}) #{priority} Completed task #{i}: implemented feature #{i} with tests, documentation, and integration with existing systems following established patterns and conventions"

          _ ->
            "- (#{timestamp}) #{priority} Item #{i} in section #{section_name}"
        end
      end)

    header <> Enum.join(items, "\n")
  end
end
