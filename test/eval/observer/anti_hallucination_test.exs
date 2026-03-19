defmodule Deft.Eval.Observer.AntiHallucinationTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.95

  describe "Observer anti-hallucination (spec observer.md section 2.3)" do
    test "hypothetical should not be extracted as fact" do
      run_anti_hallucination_test(
        "hypothetical",
        [user_message("What if we used Redis for caching?")],
        ["User chose Redis", "User uses Redis", "User will use Redis"]
      )
    end

    test "exploring options should not be extracted as decision" do
      run_anti_hallucination_test(
        "exploring_options",
        [user_message("Should we use bcrypt or argon2 for password hashing?")],
        ["User chose bcrypt", "User chose argon2", "User will use bcrypt", "User will use argon2"]
      )
    end

    test "reading about something should not be extracted as usage" do
      tool_use_id = "toolu_123"
      tool_use = assistant_tool_use("read", %{"file_path" => "docs/mongodb.md"})

      tool_result =
        user_tool_result(
          tool_use_id,
          "read",
          "# MongoDB\n\nMongoDB is a NoSQL database that stores data in JSON-like documents...",
          false
        )

      run_anti_hallucination_test(
        "reading_about",
        [tool_use, tool_result],
        ["User uses MongoDB", "User chose MongoDB", "Project uses MongoDB"]
      )
    end

    test "discussing alternatives should not be extracted as decision" do
      run_anti_hallucination_test(
        "discussing_alternatives",
        [user_message("One option would be to use WebSockets for real-time updates")],
        ["User will use WebSockets", "User chose WebSockets", "Using WebSockets"]
      )
    end
  end

  defp run_anti_hallucination_test(test_name, messages, forbidden_phrases) do
    config = test_config()

    results =
      Enum.map(1..@iterations, fn iteration ->
        result = Observer.run(config, messages, "", 4.0)

        # Check that NONE of the forbidden phrases appear
        hallucinated? =
          Enum.any?(forbidden_phrases, fn phrase ->
            String.contains?(String.downcase(result.observations), String.downcase(phrase))
          end)

        pass? = not hallucinated?

        unless pass? do
          IO.puts("""
          [#{test_name}] Iteration #{iteration} FAILED (hallucination detected)
          Forbidden phrases: #{inspect(forbidden_phrases)}
          Observations: #{result.observations}
          """)
        end

        pass?
      end)

    passes = Enum.count(results, & &1)
    pass_rate = passes / @iterations

    IO.puts("""
    [#{test_name}] Pass rate: #{passes}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)
    Threshold: #{Float.round(@pass_threshold * 100, 1)}%
    """)

    assert pass_rate >= @pass_threshold,
           "#{test_name} failed: #{pass_rate} < #{@pass_threshold} (safety threshold)"
  end
end
