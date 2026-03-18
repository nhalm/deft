defmodule Deft.Eval.Observer.SectionRoutingTest do
  @moduledoc """
  Observer section routing eval tests.

  Tests the Observer's ability to route facts to the correct sections per spec
  section 2.2. Each test runs 20 iterations with an 85% pass rate threshold.
  """

  use ExUnit.Case, async: true

  alias Deft.OM.Observer
  alias Deft.EvalHelpers

  # Mark as eval test
  @moduletag :eval
  @moduletag :expensive

  describe "Section Routing - 5 test cases, 20 iterations, 85% pass rate" do
    @tag timeout: 600_000
    test "1. User preference → User Preferences" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message("I prefer spaces over tabs for indentation.")
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must appear in User Preferences section
        assert EvalHelpers.in_section?(observations, "User Preferences", "spaces"),
               "Expected 'spaces' to appear in User Preferences section, got: #{observations}"
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

      IO.puts("\n✓ User preference routing: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "2. File read → Files & Architecture" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a file read tool result
        tool_use_msg = EvalHelpers.assistant_tool_use("read", %{file_path: "lib/config.ex"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "read",
            "defmodule Config do\n  def load(), do: :ok\nend"
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must appear in Files & Architecture section
        assert EvalHelpers.in_section?(observations, "Files & Architecture", "lib/config.ex"),
               "Expected 'lib/config.ex' to appear in Files & Architecture section, got: #{observations}"
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

      IO.puts("\n✓ File read routing: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "3. File modification → Files & Architecture" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # Simulate a file edit tool result
        tool_use_msg = EvalHelpers.assistant_tool_use("edit", %{file_path: "lib/auth.ex"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "edit",
            "Successfully edited lib/auth.ex"
          )

        messages = [tool_use_msg, tool_result_msg]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must appear in Files & Architecture section
        assert EvalHelpers.in_section?(observations, "Files & Architecture", "lib/auth.ex"),
               "Expected 'lib/auth.ex' to appear in Files & Architecture section, got: #{observations}"
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

      IO.puts("\n✓ File modification routing: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "4. Implementation decision → Decisions" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.assistant_message(
            "I chose to use ETS instead of DETS because we need fast in-memory access and don't require persistence for this cache."
          )
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must appear in Decisions section
        assert EvalHelpers.in_section?(observations, "Decisions", "ETS"),
               "Expected 'ETS' to appear in Decisions section, got: #{observations}"
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

      IO.puts("\n✓ Implementation decision routing: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "5. Current task description → Current State" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        messages = [
          EvalHelpers.user_message(
            "We're currently implementing the rate limiter module with token bucket algorithm."
          )
        ]

        result = Observer.run(config, messages, "", 4.0)
        observations = result.observations

        # Must appear in Current State section
        assert EvalHelpers.in_section?(observations, "Current State", "rate limiter"),
               "Expected 'rate limiter' to appear in Current State section, got: #{observations}"
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

      IO.puts("\n✓ Current task routing: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.85,
             "Pass rate #{trunc(pass_rate * 100)}% below 85% threshold (#{passes}/20 passed)"
    end
  end
end
