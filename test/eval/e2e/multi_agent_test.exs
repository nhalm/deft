defmodule Eval.E2E.MultiAgentTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive
  @moduletag :e2e

  # Spec: specs/testing/evals/e2e.md
  # Compares multi-agent (Foreman + Leads) vs single-agent on same tasks

  @moduledoc """
  Multi-agent comparison evaluation.
  Tests whether orchestration provides value over single-agent execution.
  """

  # TODO: Implement multi-agent comparison tests
  # - Run same task with single-agent and multi-agent modes
  # - Compare completion rate, cost, and quality
  # - Hypothesis: orchestration adds value above complexity threshold

  @tag :skip
  test "placeholder for multi-agent vs single-agent" do
    # Implement using task battery fixtures
    # See specs/testing/evals/e2e.md
    :ok
  end
end
