defmodule Eval.Spilling.CacheRetrievalTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/spilling.md
  # Validates that cache retrieval references are correctly formatted and parsed

  @moduledoc """
  Cache retrieval evaluation for spilled tool results.
  Tests that cache_read tool calls reference spilled content correctly.
  """

  # TODO: Implement cache retrieval tests
  # - Given spilled tool results
  # - Expected: Actor uses cache_read with correct references
  # - Pass rate: 85% over 20 iterations

  @tag :skip
  test "placeholder for cache retrieval behavior" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/spilling.md
    :ok
  end
end
