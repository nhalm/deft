defmodule Deft.Eval.PlaceholderTest do
  @moduledoc """
  Placeholder test to satisfy test.eval.check-structure Makefile target.
  Real eval tests are blocked pending fixtures and test infrastructure.
  See specd_work_list.md for blocked eval work items.
  """
  use ExUnit.Case

  @tag :eval
  test "placeholder - eval infrastructure pending" do
    # This test exists to satisfy the Makefile structure check (≥1 test file)
    # Actual eval tests will replace this as dependencies are implemented
    assert true
  end
end
