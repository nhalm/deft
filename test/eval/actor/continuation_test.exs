defmodule Eval.Actor.ContinuationTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/actor.md §4.2
  # Validates that Actor continues naturally after message trimming

  @moduledoc """
  Continuation evaluation for Actor.
  Tests that Actor resumes naturally mid-conversation without greeting or repetition.
  """

  # TODO: Implement continuation tests
  # - Given observations + continuation hint + 3 tail messages
  # - Expected: natural continuation, no greeting, references current task
  # - Pass rate: 90% over 20 iterations

  @tag :skip
  test "placeholder for continuation after trimming" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/actor.md §4.2
    :ok
  end
end
