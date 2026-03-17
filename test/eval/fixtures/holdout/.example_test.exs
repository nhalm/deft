defmodule Deft.Eval.Holdout.ExampleTest do
  @moduledoc """
  Example holdout test demonstrating the @tag :holdout pattern.

  Holdout tests are excluded from normal eval runs and only executed
  via `make test.eval.holdout` to validate prompt generalization.
  """

  use ExUnit.Case, async: true

  @tag :eval
  @tag :holdout
  test "example holdout test" do
    # Holdout tests verify that prompts generalize beyond development fixtures
    assert true
  end
end
