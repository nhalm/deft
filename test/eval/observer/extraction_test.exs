defmodule Deft.Eval.Observer.ExtractionTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  alias Deft.EvalHelpers
  alias Deft.OM.Observer

  @moduledoc """
  Eval tests for Observer extraction accuracy.

  Verifies that the Observer correctly extracts observations from conversation messages.
  See specs/testing/evals/observer.md for detailed eval definitions.
  """

  describe "basic extraction" do
    @tag :integration
    test "extracts explicit technology choice" do
      config = EvalHelpers.test_config()
      session_id = "test_observer_extraction"

      messages = [
        EvalHelpers.user_message("We use PostgreSQL for our database.")
      ]

      result = Observer.run(session_id, config, messages, "", 4.0)

      assert is_binary(result.observations)
      assert result.observations != ""
      assert String.contains?(result.observations, "PostgreSQL")
      assert is_list(result.message_ids)
      assert length(result.message_ids) == 1
    end

    @tag :integration
    test "returns structured result with required fields" do
      config = EvalHelpers.test_config()
      session_id = "test_observer_structure"

      messages = [
        EvalHelpers.user_message("I prefer vim keybindings in my editor.")
      ]

      result = Observer.run(session_id, config, messages, "", 4.0)

      assert Map.has_key?(result, :observations)
      assert Map.has_key?(result, :message_ids)
      assert Map.has_key?(result, :message_tokens)
      assert Map.has_key?(result, :current_task)
      assert Map.has_key?(result, :continuation_hint)
      assert is_binary(result.observations)
      assert is_list(result.message_ids)
      assert is_integer(result.message_tokens)
    end
  end
end
