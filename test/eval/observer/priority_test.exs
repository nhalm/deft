defmodule Deft.Eval.Observer.PriorityTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  describe "Observer priority assignment (spec observational-memory.md section 3.4)" do
    test "red priority for explicit user facts" do
      run_priority_test(
        "explicit_user_fact",
        [user_message("We use PostgreSQL for our database")],
        "🔴"
      )
    end

    test "red priority for user preferences" do
      run_priority_test(
        "user_preference",
        [user_message("I prefer spaces over tabs")],
        "🔴"
      )
    end

    test "yellow priority for file reads" do
      tool_use_id = "toolu_123"
      tool_use = assistant_tool_use("read", %{"file_path" => "src/auth.ex"})
      tool_result = user_tool_result(tool_use_id, "read", "defmodule Auth do\nend", false)

      run_priority_test(
        "file_read",
        [tool_use, tool_result],
        "🟡"
      )
    end

    test "yellow priority for errors encountered" do
      tool_use_id = "toolu_789"
      tool_use = assistant_tool_use("bash", %{"command" => "mix compile"})

      tool_result =
        user_tool_result(
          tool_use_id,
          "bash",
          "** (CompileError) lib/auth.ex:42: undefined function foo/1",
          true
        )

      run_priority_test(
        "error_encountered",
        [tool_use, tool_result],
        "🟡"
      )
    end

    test "yellow priority for architectural decisions" do
      run_priority_test(
        "architectural_decision",
        [user_message("Let's use gen_statem for the agent loop because it has explicit states")],
        "🟡"
      )
    end
  end

  defp run_priority_test(test_name, messages, expected_priority) do
    config = test_config()

    results =
      Enum.map(1..@iterations, fn iteration ->
        result = Observer.run(config, messages, "", 4.0)

        # Check if the expected priority marker is present
        pass? = String.contains?(result.observations, expected_priority)

        unless pass? do
          IO.puts("""
          [#{test_name}] Iteration #{iteration} FAILED
          Expected priority: #{expected_priority}
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
           "#{test_name} failed: #{pass_rate} < #{@pass_threshold}"
  end
end
