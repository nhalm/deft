defmodule Deft.Eval.Observer.DedupTest do
  @moduledoc """
  Observer deduplication eval tests.

  Tests the Observer's ability to avoid re-extracting facts that are already
  present in existing observations per spec section 2.4. Each test runs
  20 iterations with an 80% pass rate threshold.
  """

  use ExUnit.Case, async: true

  alias Deft.OM.Observer
  alias Deft.EvalHelpers

  # Mark as eval test
  @moduletag :eval
  @moduletag :expensive

  describe "Deduplication - 3 test cases, 20 iterations, 80% pass rate" do
    @tag timeout: 600_000
    test "1. User preferences already observed" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # First pass: establish baseline observations
        initial_messages = [
          EvalHelpers.user_message("I prefer spaces over tabs for indentation."),
          EvalHelpers.user_message("We use PostgreSQL for our database.")
        ]

        initial_result = Observer.run(config, initial_messages, "", 4.0)
        existing_observations = initial_result.observations

        # Verify initial extraction worked
        assert String.contains?(existing_observations, "spaces") or
                 String.contains?(existing_observations, "prefer"),
               "Initial extraction failed to capture preferences"

        # Second pass: repeat the same facts
        duplicate_messages = [
          EvalHelpers.user_message("Just to confirm, I prefer spaces over tabs."),
          EvalHelpers.user_message("Remember, we're using PostgreSQL.")
        ]

        dedup_result = Observer.run(config, duplicate_messages, existing_observations, 4.0)
        new_observations = dedup_result.observations

        # The new observations should not re-extract the same facts
        # We check that the new observations are relatively empty or don't add redundant info
        # A simple heuristic: if dedup works, new_observations should be much shorter than initial
        # or explicitly state no new facts
        new_obs_lower = String.downcase(new_observations)

        # Another signal: new observations don't repeat the core facts
        dedup_worked =
          String.length(new_observations) < 50 or
            String.contains?(new_obs_lower, "no new") or
            String.contains?(new_obs_lower, "already") or
            String.contains?(new_obs_lower, "previously") or
            String.contains?(new_obs_lower, "duplicate") or
            not (String.contains?(new_observations, "spaces") and
                   String.contains?(new_observations, "tabs") and
                   String.contains?(new_observations, "PostgreSQL"))

        assert dedup_worked,
               "Observer re-extracted facts already in existing observations. Initial: #{initial_result.observations}, New: #{new_observations}"
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

      IO.puts("\n✓ User preferences dedup: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.80,
             "Pass rate #{trunc(pass_rate * 100)}% below 80% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "2. File operations already observed" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # First pass: observe file operations
        tool_use_msg = EvalHelpers.assistant_tool_use("read", %{file_path: "src/auth.ex"})
        tool_use_id = hd(tool_use_msg.content).id

        tool_result_msg =
          EvalHelpers.user_tool_result(
            tool_use_id,
            "read",
            "defmodule Auth do\n  def verify(token), do: :ok\nend"
          )

        initial_messages = [tool_use_msg, tool_result_msg]

        initial_result = Observer.run(config, initial_messages, "", 4.0)
        existing_observations = initial_result.observations

        # Verify initial extraction worked
        assert String.contains?(existing_observations, "src/auth.ex"),
               "Initial extraction failed to capture file read"

        # Second pass: repeat the same file operation
        tool_use_msg2 = EvalHelpers.assistant_tool_use("read", %{file_path: "src/auth.ex"})
        tool_use_id2 = hd(tool_use_msg2.content).id

        tool_result_msg2 =
          EvalHelpers.user_tool_result(
            tool_use_id2,
            "read",
            "defmodule Auth do\n  def verify(token), do: :ok\nend"
          )

        duplicate_messages = [tool_use_msg2, tool_result_msg2]

        dedup_result = Observer.run(config, duplicate_messages, existing_observations, 4.0)
        new_observations = dedup_result.observations

        # Check for deduplication
        new_obs_lower = String.downcase(new_observations)

        # The file shouldn't be mentioned again in detail
        dedup_worked =
          String.length(new_observations) < 50 or
            String.contains?(new_obs_lower, "no new") or
            String.contains?(new_obs_lower, "already") or
            String.contains?(new_obs_lower, "previously") or
            not String.contains?(new_observations, "src/auth.ex")

        assert dedup_worked,
               "Observer re-extracted file read already in existing observations. Initial: #{initial_result.observations}, New: #{new_observations}"
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

      IO.puts("\n✓ File operations dedup: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.80,
             "Pass rate #{trunc(pass_rate * 100)}% below 80% threshold (#{passes}/20 passed)"
    end

    @tag timeout: 600_000
    test "3. Mixed facts already observed" do
      config = EvalHelpers.test_config()

      test_fn = fn ->
        # First pass: establish multiple facts
        initial_messages = [
          EvalHelpers.user_message("We use gen_statem for the agent state machine."),
          EvalHelpers.user_message("Add the jason dependency version 1.4 to mix.exs."),
          EvalHelpers.assistant_message(
            "I've added jason ~> 1.4 to the dependencies. We still need to test the JSON encoding later."
          )
        ]

        initial_result = Observer.run(config, initial_messages, "", 4.0)
        existing_observations = initial_result.observations

        # Verify initial extraction captured something
        assert String.length(existing_observations) > 50,
               "Initial extraction failed to capture facts"

        # Second pass: repeat some of the facts in different wording
        duplicate_messages = [
          EvalHelpers.user_message("Remember we're using gen_statem for state management."),
          EvalHelpers.user_message("Jason 1.4 should be in our dependencies now."),
          # Add a genuinely new fact to test that we still extract new things
          EvalHelpers.user_message("We should also add timex for date handling.")
        ]

        dedup_result = Observer.run(config, duplicate_messages, existing_observations, 4.0)
        new_observations = dedup_result.observations

        # The new observations should mention the new fact (timex) but not re-extract old ones
        # This is a more nuanced test: we want to see new facts extracted but old ones skipped
        mentions_new_fact =
          String.contains?(new_observations, "timex") or
            String.contains?(new_observations, "date")

        # Count how many old facts are re-mentioned (should be minimal)
        old_fact_count =
          [
            String.contains?(new_observations, "gen_statem"),
            String.contains?(new_observations, "jason"),
            String.contains?(new_observations, "1.4")
          ]
          |> Enum.count(& &1)

        # Good dedup: extracts new fact but doesn't re-extract more than 1 old fact
        dedup_worked = mentions_new_fact and old_fact_count <= 1

        assert dedup_worked,
               "Observer failed to extract new fact (timex) or re-extracted too many old facts. New: #{new_observations}"
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

      IO.puts("\n✓ Mixed facts dedup: #{passes}/20 (#{trunc(pass_rate * 100)}%)")

      assert pass_rate >= 0.80,
             "Pass rate #{trunc(pass_rate * 100)}% below 80% threshold (#{passes}/20 passed)"
    end
  end
end
