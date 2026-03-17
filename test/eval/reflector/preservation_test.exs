defmodule Deft.Eval.Reflector.PreservationTest do
  use ExUnit.Case, async: false

  alias Deft.{Config, Provider}
  alias Deft.OM.Reflector
  alias Deft.Eval.ResultStore

  @moduletag :eval
  @moduletag :expensive

  @fixture_path "test/eval/fixtures/observation_sets/mixed_priority_items.txt"
  @iterations 20
  @pass_rate_threshold 0.95
  @target_size 20_000
  @calibration_factor 4.0

  setup_all do
    # Skip if no API key
    unless System.get_env("ANTHROPIC_API_KEY") do
      ExUnit.configure(exclude: [:eval])
      :skip
    else
      # Register Anthropic provider for LLM calls
      :ok = Provider.Registry.register("anthropic", Deft.Provider.Anthropic)
      :ok
    end
  end

  describe "Reflector high-priority preservation" do
    @tag timeout: 600_000
    test "preserves all 🔴 items through compression" do
      # Load fixture
      observations = File.read!(@fixture_path)

      # Extract all 🔴 items from input
      red_items = extract_red_items(observations)

      # Verify fixture has expected number of red items
      assert length(red_items) == 10,
             "Fixture should contain exactly 10 🔴 items, found #{length(red_items)}"

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

      # Run iterations
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts("\n[Iteration #{iteration}/#{@iterations}]")

          result = Reflector.run(config, observations, @target_size, @calibration_factor)

          # Check which red items survived
          survived =
            Enum.filter(red_items, fn item ->
              String.contains?(result.compressed_observations, item)
            end)

          all_survived = length(survived) == length(red_items)

          IO.puts(
            "  #{length(survived)}/#{length(red_items)} 🔴 items preserved (#{result.before_tokens} → #{result.after_tokens} tokens, level #{result.compression_level})"
          )

          %{
            iteration: iteration,
            all_red_survived: all_survived,
            red_survived_count: length(survived),
            red_total_count: length(red_items),
            missing_items: red_items -- survived,
            before_tokens: result.before_tokens,
            after_tokens: result.after_tokens,
            compression_level: result.compression_level,
            llm_calls: result.llm_calls
          }
        end)

      # Calculate pass rate
      passes = Enum.count(results, & &1.all_red_survived)
      pass_rate = passes / @iterations

      # Calculate confidence interval (Wilson score interval)
      {ci_low, ci_high} = wilson_score_interval(passes, @iterations)

      # Collect failures for reporting
      failures =
        results
        |> Enum.reject(& &1.all_red_survived)
        |> Enum.map(fn result ->
          %{
            iteration: result.iteration,
            missing_items: result.missing_items,
            red_survived_count: result.red_survived_count,
            compression_level: result.compression_level
          }
        end)

      # Calculate average cost (rough estimate: haiku at $0.25/$1.25 per MTok)
      avg_input_tokens = Enum.sum(Enum.map(results, & &1.before_tokens)) / @iterations
      avg_output_tokens = Enum.sum(Enum.map(results, & &1.after_tokens)) / @iterations
      avg_llm_calls = Enum.sum(Enum.map(results, & &1.llm_calls)) / @iterations

      cost_usd =
        (avg_input_tokens * avg_llm_calls * 0.25 + avg_output_tokens * avg_llm_calls * 1.25) /
          1_000_000

      # Store result
      run_id = ResultStore.generate_run_id()
      commit = ResultStore.get_commit_sha()

      result_data = %{
        run_id: run_id,
        commit: commit,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        model: config.om_reflector_model,
        category: "reflector.preservation",
        pass_rate: pass_rate,
        iterations: @iterations,
        cost_usd: cost_usd,
        failures: failures
      }

      ResultStore.store(result_data)

      # Report results
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Reflector High-Priority Preservation Eval")
      IO.puts(String.duplicate("=", 70))
      IO.puts("Result: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("CI: [#{Float.round(ci_low * 100, 1)}%-#{Float.round(ci_high * 100, 1)}%]")
      IO.puts("Threshold: #{Float.round(@pass_rate_threshold * 100, 1)}%")
      IO.puts("Cost: $#{Float.round(cost_usd, 2)}")
      IO.puts("Run ID: #{run_id}")

      if pass_rate >= @pass_rate_threshold do
        IO.puts("Status: ✓ PASS")
      else
        IO.puts("Status: ✗ FAIL")

        IO.puts("\nFailure details:")

        Enum.each(failures, fn failure ->
          IO.puts("  Iteration #{failure.iteration}:")
          IO.puts("    Survived: #{failure.red_survived_count}/10")
          IO.puts("    Compression level: #{failure.compression_level}")

          if length(failure.missing_items) > 0 do
            IO.puts("    Missing items:")

            Enum.each(failure.missing_items, fn item ->
              IO.puts("      - #{String.slice(item, 0..80)}...")
            end)
          end
        end)
      end

      IO.puts(String.duplicate("=", 70))

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_rate_threshold,
             """
             Reflector preservation eval failed: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)
             Expected: >= #{Float.round(@pass_rate_threshold * 100, 1)}%
             CI: [#{Float.round(ci_low * 100, 1)}%-#{Float.round(ci_high * 100, 1)}%]

             #{length(failures)} iterations failed to preserve all 🔴 items.
             Run ID: #{run_id}
             """
    end
  end

  # Helper functions

  defp extract_red_items(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line -> String.contains?(line, "🔴") end)
    |> Enum.map(&String.trim/1)
  end

  # Wilson score interval for binomial proportion confidence interval
  # Returns {lower_bound, upper_bound} for 95% confidence
  defp wilson_score_interval(successes, trials) do
    if trials == 0 do
      {0.0, 0.0}
    else
      p = successes / trials
      # 95% confidence
      z = 1.96

      denominator = 1 + z * z / trials
      center = (p + z * z / (2 * trials)) / denominator
      margin = z * :math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials)) / denominator

      {max(0.0, center - margin), min(1.0, center + margin)}
    end
  end
end
