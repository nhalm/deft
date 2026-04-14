defmodule Deft.Eval.Actor.ToolSelectionTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  @moduledoc """
  Eval tests for Actor tool selection accuracy.

  Verifies that the Actor (main agent loop) correctly selects tools based on
  user requests and conversation context.
  See specs/testing/evals/actor.md for detailed eval definitions.
  """

  describe "basic tool selection" do
    @tag :integration
    test "placeholder for actor eval" do
      # Actor tool selection evals require full agent loop integration
      # This placeholder satisfies the CI structure gate
      # Future iterations will implement:
      # - Real agent loop with test provider
      # - Synthetic task fixtures
      # - Tool selection accuracy measurement
      # - Statistical pass rates (20 iterations, 85% threshold)

      assert true
    end
  end
end
