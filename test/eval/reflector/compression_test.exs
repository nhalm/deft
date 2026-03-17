defmodule Deft.Eval.Reflector.CompressionTest do
  @moduledoc """
  Reflector compression eval test.

  Tests that the Reflector compresses 40k token observations to ≤20k tokens
  (50% of the reflection threshold) in ≥90% of 20 iterations.
  """
  use ExUnit.Case, async: false

  alias Deft.{Config, OM.Reflector, OM.Tokens, Provider}

  @moduletag :eval
  @moduletag :expensive
  @moduletag timeout: :infinity

  @fixture_path "test/eval/fixtures/observation_sets/large_observations_40k.txt"
  @target_size 20_000
  @calibration_factor 4.0
  @iterations 20
  @required_pass_rate 0.90

  setup do
    :ok = Provider.Registry.register("anthropic", Provider.Anthropic)

    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      %{skip: true, skip_reason: "ANTHROPIC_API_KEY not set"}
    else
      %{skip: false, skip_reason: nil}
    end
  end

  describe "Reflector compression target eval" do
    test "compresses 40k token observations to ≤20k tokens in ≥90% of iterations",
         %{skip: skip, skip_reason: reason} do
      if skip do
        IO.puts("\nSkipping: #{reason}")
        :ok
      else
        run_compression_eval()
      end
    end
  end

  defp run_compression_eval do
    observations = File.read!(@fixture_path)
    initial_tokens = Tokens.estimate(observations, @calibration_factor)

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Reflector Compression Eval")
    IO.puts("Initial size: #{initial_tokens} tokens")
    IO.puts("Target: ≤#{@target_size} tokens")
    IO.puts("Iterations: #{@iterations}")
    IO.puts(String.duplicate("=", 80))

    config = Config.load()

    results =
      for iteration <- 1..@iterations do
        result = Reflector.run(config, observations, @target_size, @calibration_factor)
        passed = result.after_tokens <= @target_size

        %{
          iteration: iteration,
          passed: passed,
          before_tokens: result.before_tokens,
          after_tokens: result.after_tokens,
          compression_level: result.compression_level
        }
      end

    passes = Enum.count(results, & &1.passed)
    pass_rate = passes / @iterations

    IO.puts("Results: #{passes}/#{@iterations} (#{trunc(pass_rate * 100)}%)")

    assert pass_rate >= @required_pass_rate,
           "Pass rate #{trunc(pass_rate * 100)}% below required #{trunc(@required_pass_rate * 100)}%"
  end
end
