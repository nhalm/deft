defmodule Eval.Observer.PriorityTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/observer.md §2.1
  # Validates that Observer correctly prioritizes facts (🔴, 🟡) based on importance

  @moduledoc """
  Priority evaluation for Observer fact extraction.
  Tests that high-priority facts (explicit tech choices, preferences) are correctly marked.
  """

  # TODO: Implement priority classification tests
  # - Explicit tech choices should be 🔴 priority
  # - Preferences should be 🔴 priority
  # - File operations should be 🟡 priority
  # - Pass rate: 85% over 20 iterations

  @tag :skip
  test "placeholder for priority classification" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/observer.md §2.1
    :ok
  end
end
