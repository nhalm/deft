defmodule Deft.Eval.Observer.SectionRoutingTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  describe "Observer section routing (spec observer.md section 2.2)" do
    test "user preference routes to User Preferences section" do
      run_section_test(
        "user_preference_section",
        [user_message("I prefer spaces over tabs")],
        "User Preferences",
        "spaces"
      )
    end

    test "file read routes to Files & Architecture section" do
      tool_use_id = "toolu_123"
      tool_use = assistant_tool_use("read", %{"file_path" => "src/auth.ex"})
      tool_result = user_tool_result(tool_use_id, "read", "defmodule Auth do\nend", false)

      run_section_test(
        "file_read_section",
        [tool_use, tool_result],
        "Files & Architecture",
        "auth.ex"
      )
    end

    test "file modification routes to Files & Architecture section" do
      tool_use_id = "toolu_456"

      tool_use =
        assistant_tool_use("edit", %{
          "file_path" => "src/router.ex",
          "old_string" => "old",
          "new_string" => "new"
        })

      tool_result = user_tool_result(tool_use_id, "edit", "File edited successfully", false)

      run_section_test(
        "file_modification_section",
        [tool_use, tool_result],
        "Files & Architecture",
        "router.ex"
      )
    end

    test "implementation decision routes to Decisions section" do
      run_section_test(
        "decision_section",
        [user_message("Let's use gen_statem for the agent loop because it has explicit states")],
        "Decisions",
        "gen_statem"
      )
    end

    test "current task routes to Current State section" do
      run_section_test(
        "current_task_section",
        [user_message("Now implement the authentication handler")],
        "Current State",
        "authentication"
      )
    end

    test "general conversation event routes to Session History section" do
      run_section_test(
        "session_history_section",
        [
          user_message("Please explain how the auth module works"),
          assistant_message(
            "The auth module handles JWT verification using the verify_token/1 function"
          )
        ],
        "Session History",
        "auth module"
      )
    end
  end

  defp run_section_test(test_name, messages, expected_section, content_marker) do
    config = test_config()

    results =
      Enum.map(1..@iterations, fn iteration ->
        result = Observer.run(config, messages, "", 4.0)

        # Check if content is in the expected section
        pass? = in_section?(result.observations, expected_section, content_marker)

        unless pass? do
          IO.puts("""
          [#{test_name}] Iteration #{iteration} FAILED
          Expected section: #{expected_section}
          Content marker: #{content_marker}
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
