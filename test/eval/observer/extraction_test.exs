defmodule Deft.Eval.Observer.ExtractionTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  describe "Observer extraction accuracy (spec observer.md section 2.1)" do
    test "explicit tech choice extraction" do
      run_extraction_test(
        "explicit_tech_choice",
        [user_message("We use PostgreSQL for our database")],
        ["PostgreSQL"]
      )
    end

    test "preference statement extraction" do
      run_extraction_test(
        "preference_statement",
        [user_message("I prefer spaces over tabs")],
        ["spaces", "prefer"]
      )
    end

    test "file read extraction" do
      # Create a tool result for a file read
      tool_use_id = "toolu_123"
      tool_use = assistant_tool_use("read", %{"file_path" => "src/auth.ex"})
      tool_result = user_tool_result(tool_use_id, "read", "defmodule Auth do\nend", false)

      run_extraction_test(
        "file_read",
        [tool_use, tool_result],
        ["src/auth.ex"]
      )
    end

    test "file modification extraction" do
      tool_use_id = "toolu_456"

      tool_use =
        assistant_tool_use("edit", %{
          "file_path" => "src/auth.ex",
          "old_string" => "old code",
          "new_string" => "new code"
        })

      tool_result = user_tool_result(tool_use_id, "edit", "File edited successfully", false)

      run_extraction_test(
        "file_modification",
        [tool_use, tool_result],
        ["Modified", "src/auth.ex"]
      )
    end

    test "error encountered extraction" do
      tool_use_id = "toolu_789"
      tool_use = assistant_tool_use("bash", %{"command" => "mix compile"})

      tool_result =
        user_tool_result(
          tool_use_id,
          "bash",
          "** (CompileError) lib/auth.ex:42: undefined function foo/1",
          true
        )

      run_extraction_test(
        "error_encountered",
        [tool_use, tool_result],
        ["CompileError", "line 42"]
      )
    end

    test "command run extraction" do
      tool_use_id = "toolu_abc"
      tool_use = assistant_tool_use("bash", %{"command" => "mix test"})

      tool_result =
        user_tool_result(
          tool_use_id,
          "bash",
          "Finished in 0.5 seconds\n12 tests, 2 failures",
          false
        )

      run_extraction_test(
        "command_run",
        [tool_use, tool_result],
        ["mix test", "2 failures"]
      )
    end

    test "architectural decision extraction" do
      run_extraction_test(
        "architectural_decision",
        [user_message("Let's use gen_statem for the agent loop because it has explicit states")],
        ["gen_statem"]
      )
    end

    test "dependency added extraction" do
      run_extraction_test(
        "dependency_added",
        [user_message("Add jason ~> 1.4 to the deps")],
        ["jason", "1.4"]
      )
    end

    test "deferred work extraction" do
      run_extraction_test(
        "deferred_work",
        [user_message("We still need to handle the error case later")],
        ["error case"]
      )
    end
  end

  defp run_extraction_test(test_name, messages, required_content) do
    config = test_config()

    results =
      Enum.map(1..@iterations, fn iteration ->
        result = Observer.run(config, messages, "", 4.0)

        # Check if all required content is present in observations
        pass? = contains_all?(result.observations, required_content)

        unless pass? do
          IO.puts("""
          [#{test_name}] Iteration #{iteration} FAILED
          Required: #{inspect(required_content)}
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
