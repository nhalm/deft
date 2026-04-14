defmodule Eval.Actor.ToolSelectionTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/actor.md §2.1
  # Validates that Actor selects appropriate tools for tasks

  @moduledoc """
  Tool selection evaluation for Actor.
  Tests that the Actor chooses the correct tools for different task types.
  """

  # TODO: Implement tool selection tests
  # - File reading tasks should select read_file tool
  # - Code execution tasks should select appropriate tools
  # - Tool selection should be appropriate for context
  # - Pass rate threshold to be determined

  @tag :skip
  test "placeholder for tool selection" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/actor.md §2.1
    :ok
  end
end
