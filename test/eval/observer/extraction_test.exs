defmodule Deft.Eval.Observer.ExtractionTest do
  @moduledoc """
  Observer extraction eval tests.

  Tests the Observer's ability to extract facts from conversations per spec
  section 2.1. Each test runs 20 iterations with an 85% pass rate threshold.
  """

  use ExUnit.Case, async: true

  alias Deft.OM.Observer
  alias Deft.EvalHelpers

  # Mark as eval test
  @moduletag :eval
  @moduletag :expensive

  describe "Fact Extraction - 9 test cases, 20 iterations, 85% pass rate" do
    @tag timeout: 600_000
    test "1. Explicit tech choice" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message("We use PostgreSQL for our database.")
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "PostgreSQL"
        assert EvalHelpers.contains_all?(observations, ["PostgreSQL"]),
               "Expected observations to contain 'PostgreSQL', got: #{observations}"
      end

      # Run 20 iterations
      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Explicit tech choice: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "2. Preference statement" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message("I prefer spaces over tabs.")
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "spaces" AND "prefer"
        assert EvalHelpers.contains_all?(observations, ["spaces", "prefer"]),
               "Expected observations to contain 'spaces' and 'prefer', got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Preference statement: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "3. File read" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a file read tool result
        tool_use_msg = EvalHelpers.assistant_tool_use("read", %{file_path: "src/auth.ex"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "read",
            "defmodule Auth do\n  def verify(token), do: :ok\nend"
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain file path "src/auth.ex"
        assert EvalHelpers.contains_all?(observations, ["src/auth.ex"]),
               "Expected observations to contain 'src/auth.ex', got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ File read: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "4. File modification" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a file edit tool result
        tool_use_msg = EvalHelpers.assistant_tool_use("edit", %{file_path: "src/auth.ex"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "edit",
            "Successfully edited src/auth.ex"
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "Modified" or similar AND "src/auth.ex"
        contains_modification =
          String.contains?(observations, "edit") or
            String.contains?(observations, "modif") or
            String.contains?(observations, "chang")

        assert contains_modification and String.contains?(observations, "src/auth.ex"),
               "Expected observations to contain modification indicator and 'src/auth.ex', got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ File modification: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "5. Error encountered" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a bash command with error output
        tool_use_msg = EvalHelpers.assistant_tool_use("bash", %{command: "mix compile"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "bash",
            "** (CompileError) lib/auth.ex:42: undefined function verify/2",
            true
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain error message (or close approximation)
        contains_error =
          String.contains?(observations, "CompileError") or
            String.contains?(observations, "error") or
            String.contains?(observations, "undefined function")

        assert contains_error,
               "Expected observations to contain error information, got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Error encountered: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "6. Command run" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a test command with results
        tool_use_msg = EvalHelpers.assistant_tool_use("bash", %{command: "mix test"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "bash",
            "Finished in 0.5 seconds\n12 tests, 2 failures"
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "mix test" AND "2 failures"
        assert EvalHelpers.contains_all?(observations, ["mix test", "2 failures"]) or
                 EvalHelpers.contains_all?(observations, ["test", "2 fail"]),
               "Expected observations to contain 'mix test' and '2 failures', got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Command run: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "7. Architectural decision" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message(
            "Let's use gen_statem for the agent loop because it has explicit states and better handles complex state transitions."
          )
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "gen_statem" AND rationale
        contains_rationale =
          String.contains?(observations, "explicit states") or
            String.contains?(observations, "state transitions") or
            String.contains?(observations, "because")

        assert String.contains?(observations, "gen_statem") and contains_rationale,
               "Expected observations to contain 'gen_statem' and rationale, got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Architectural decision: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "8. Dependency added" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message("Add jason ~> 1.4 to the deps.")
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "jason" AND version
        assert EvalHelpers.contains_all?(observations, ["jason", "1.4"]),
               "Expected observations to contain 'jason' and version '1.4', got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Dependency added: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "9. Deferred work" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.assistant_message(
            "I've implemented the basic login flow. We still need to handle the error case for invalid tokens later."
          )
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must contain "error case" AND deferred/TODO indicator
        contains_deferral =
          String.contains?(observations, "later") or
            String.contains?(observations, "still need") or
            String.contains?(observations, "TODO") or
            String.contains?(observations, "deferred")

        assert String.contains?(observations, "error") and contains_deferral,
               "Expected observations to contain 'error case' and deferral indicator, got: #{observations}"
      end

      results =
        Enum.map(1..20, fn _i ->
          try do
            test_fn.()
            :pass
          rescue
            e -> {:fail, Exception.message(e)}
          end
        end)

      passes = Enum.count(results, &(&1 == :pass))
      pass_rate = passes / 20

      IO.puts("\n✓ Deferred work: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end
  end
end
