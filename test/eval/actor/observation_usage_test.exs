defmodule Eval.Actor.ObservationUsageTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/actor.md §4.1
  # Validates that Actor uses observations to inform responses

  @moduledoc """
  Observation usage evaluation for Actor.
  Tests that Actor references and applies information from observations.
  """

  # TODO: Implement observation usage tests
  # - Given observations containing "User prefers argon2"
  # - Prompt: "implement the login endpoint"
  # - Expected: response references argon2, not bcrypt
  # - Pass rate: 85% over 20 iterations

  @tag :skip
  test "placeholder for observation usage" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/actor.md §4.1
    :ok
  end
end
