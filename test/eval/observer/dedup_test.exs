defmodule Eval.Observer.DedupTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/observer.md §2.4
  # Validates that Observer does not re-extract already-observed facts

  @moduledoc """
  Deduplication evaluation for Observer.
  Tests that Observer avoids extracting facts already present in observations.
  """

  # TODO: Implement deduplication tests
  # - Given existing observations + new messages repeating facts
  # - Expect no re-extraction of already-present facts
  # - Pass rate: 80% over 20 iterations

  @tag :skip
  test "placeholder for deduplication" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/observer.md §2.4
    :ok
  end
end
