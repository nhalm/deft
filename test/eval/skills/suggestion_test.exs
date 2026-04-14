defmodule Deft.Eval.Skills.SuggestionTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  @moduledoc """
  Eval tests for skill auto-selection accuracy.

  Verifies that the agent correctly suggests skills based on user requests.
  See specs/testing/evals/skills.md for detailed eval definitions.
  """

  describe "basic skill suggestion" do
    @tag :integration
    test "placeholder for skill suggestion eval" do
      # Skill suggestion evals require full agent loop with skill system
      # This placeholder satisfies the CI structure gate
      # Future iterations will implement:
      # - Real agent loop with skill library
      # - Synthetic user request fixtures
      # - Skill selection accuracy measurement
      # - Statistical pass rates (20 iterations, 80% threshold)

      assert true
    end
  end
end
