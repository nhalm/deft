defmodule Eval.Skills.SuggestionTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/skills.md §2.1
  # Validates that skill auto-selection suggests appropriate skills

  @moduledoc """
  Skill suggestion evaluation.
  Tests that the agent correctly identifies when skills should be suggested.
  """

  # TODO: Implement skill suggestion tests
  # - Appropriate skills should be suggested for relevant tasks
  # - Skills should not be over-suggested for simple tasks
  # - Skill selection should match task requirements
  # - Pass rate: 80% over 20 iterations

  @tag :skip
  test "placeholder for skill suggestion" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/skills.md §2.1
    :ok
  end
end
