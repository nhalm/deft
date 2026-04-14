defmodule Eval.Lead.SteeringTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  # Spec: specs/testing/evals/lead.md
  # Validates that Lead correctly steers Runners toward task completion

  @moduledoc """
  Steering evaluation for Lead.
  Tests that Lead provides effective guidance to Runners.
  """

  # TODO: Implement steering tests
  # - Given a task contract and Runner behavior
  # - Expected: Lead steers Runner toward completion
  # - Pass rate: 75% over 20 iterations

  @tag :skip
  test "placeholder for steering quality" do
    # Implement using Tribunal LLM-as-judge assertions
    # See specs/testing/evals/lead.md
    :ok
  end
end
