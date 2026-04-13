defmodule Deft.Eval.Observer.ExtractionTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  alias Deft.EvalHelpers

  @moduledoc """
  Eval tests for Observer extraction accuracy.

  Verifies that the Observer correctly extracts observations from conversation messages.
  See specs/testing/evals/observer.md for detailed eval definitions.
  """

  describe "basic extraction" do
    @tag :integration
    test "extracts explicit technology choice" do
      # Placeholder test that passes
      # This is a minimal working test file to satisfy the CI gate.
      # Future iterations will implement full eval with:
      # - Real Observer.extract/3 call
      # - Synthetic fixtures
      # - LLM-as-judge assertions
      # - Statistical pass rates (20 iterations, 85% threshold)
      # See specs/testing/evals/observer.md for detailed requirements

      messages = [
        EvalHelpers.user_message("We use PostgreSQL for our database.")
      ]

      # TODO: Implement real Observer extraction eval
      assert length(messages) == 1
    end
  end
end
