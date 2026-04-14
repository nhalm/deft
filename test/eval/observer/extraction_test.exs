defmodule Eval.Observer.ExtractionTest do
  use ExUnit.Case, async: false
  @moduletag :eval
  @moduletag :expensive

  # Spec: specs/testing/evals/observer.md §2.1
  # Validates that Observer correctly extracts facts from user messages

  @moduledoc """
  Extraction evaluation for Observer fact extraction.
  Tests that facts are correctly identified and extracted from conversations.
  """

  # TODO: Implement extraction accuracy tests
  # - Explicit tech choices should be extracted
  # - User preferences should be extracted
  # - Contextual facts should be extracted
  # - Pass rate: 85% over 20 iterations

  @tag :skip
  test "placeholder for fact extraction" do
    # Implement using Tribunal assertions
    # See specs/testing/evals/observer.md §2.1
    :ok
  end
end
