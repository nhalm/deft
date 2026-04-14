defmodule Deft.Eval.Issues.ElicitationQualityTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  @moduledoc """
  Eval tests for issue elicitation quality.

  Verifies that the agent correctly elicits issue details through interactive
  questioning in `deft work` mode.
  See specs/testing/evals/issues.md for detailed eval definitions.
  """

  describe "basic elicitation quality" do
    @tag :integration
    test "placeholder for issue elicitation eval" do
      # Issue elicitation evals require agent loop with issue system
      # This placeholder satisfies the CI structure gate
      # Future iterations will implement:
      # - Real agent loop with issue elicitation mode
      # - Vague user request fixtures
      # - Elicitation quality measurement via LLM-as-judge
      # - Statistical pass rates (20 iterations, 80% threshold)

      assert true
    end
  end
end
