defmodule Deft.Eval.Observer.DedupTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.80

  describe "Observer deduplication (spec observer.md section 2.4)" do
    test "does not re-extract already observed tech choice" do
      # First observation: user states PostgreSQL usage
      existing_observations = """
      ## User Preferences
      - 🔴 User uses PostgreSQL for database
      """

      # Second message repeating the same fact
      messages = [user_message("As I mentioned, we use PostgreSQL")]

      run_dedup_test(
        "tech_choice_dedup",
        messages,
        existing_observations,
        "PostgreSQL"
      )
    end

    test "does not re-extract already observed file read" do
      existing_observations = """
      ## Files & Architecture
      - 🟡 Read src/auth.ex — contains JWT verification
      """

      # Second file read of the same file
      tool_use_id = "toolu_456"
      tool_use = assistant_tool_use("read", %{"file_path" => "src/auth.ex"})
      tool_result = user_tool_result(tool_use_id, "read", "defmodule Auth do\nend", false)

      run_dedup_test(
        "file_read_dedup",
        [tool_use, tool_result],
        existing_observations,
        "auth.ex"
      )
    end

    test "does not re-extract already observed preference" do
      existing_observations = """
      ## User Preferences
      - 🔴 User prefers spaces over tabs
      """

      messages = [user_message("Remember, I prefer spaces, not tabs")]

      run_dedup_test(
        "preference_dedup",
        messages,
        existing_observations,
        "spaces"
      )
    end

    test "does not re-extract already observed architectural decision" do
      existing_observations = """
      ## Decisions
      - 🟡 Chose gen_statem for agent loop (explicit state management)
      """

      messages = [user_message("Let's continue with gen_statem for the agent as we decided")]

      run_dedup_test(
        "decision_dedup",
        messages,
        existing_observations,
        "gen_statem"
      )
    end
  end

  defp run_dedup_test(test_name, messages, existing_observations, fact_marker) do
    config = test_config()

    results =
      Enum.map(1..@iterations, fn iteration ->
        result = Observer.run(config, messages, existing_observations, 4.0)

        # The new observation should either:
        # 1. Be empty (best case - nothing new to observe)
        # 2. Not contain the already-observed fact marker (dedup worked)
        new_obs = String.trim(result.observations)

        pass? =
          new_obs == "" or
            not String.contains?(String.downcase(new_obs), String.downcase(fact_marker))

        unless pass? do
          IO.puts("""
          [#{test_name}] Iteration #{iteration} FAILED (duplicate extraction)
          Fact marker: #{fact_marker}
          New observations: #{result.observations}
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
           "#{test_name} failed: #{pass_rate} < #{@pass_threshold}"
  end
end
