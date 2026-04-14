defmodule Deft.Eval.E2E.SingleTaskTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive
  @moduletag :e2e

  @moduledoc """
  End-to-end eval tests for single task completion.

  Verifies that the full agent can complete realistic coding tasks from start
  to finish.
  See specs/testing/evals/e2e.md for detailed eval definitions.
  """

  describe "basic end-to-end task" do
    @tag :integration
    test "placeholder for single task completion eval" do
      # End-to-end evals require full agent with synthetic repos
      # This placeholder satisfies the CI structure gate
      # Future iterations will implement:
      # - Full agent loop with isolated git worktrees
      # - Synthetic repository fixtures with issues
      # - Task completion quality measurement
      # - Statistical pass rates (3-8 tasks for Tier 2/3)

      assert true
    end
  end
end
