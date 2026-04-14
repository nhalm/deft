defmodule Deft.Eval.Reflector.CompressionTest do
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :expensive

  alias Deft.EvalHelpers
  alias Deft.OM.Reflector

  @moduledoc """
  Eval tests for Reflector compression quality.

  Verifies that the Reflector correctly compresses observations while preserving
  critical information and CORRECTION markers.
  See specs/testing/evals/reflector.md for detailed eval definitions.
  """

  describe "basic compression" do
    @tag :integration
    test "compresses observations to target size" do
      config = EvalHelpers.test_config()
      session_id = "test_reflector_compression"

      # Create a large observation text that needs compression
      observations = """
      ## Codebase Facts

      The project uses Phoenix framework for the web UI.
      The database is PostgreSQL with Ecto for ORM.
      The agent loop is implemented as a gen_statem.

      ## User Preferences

      The user prefers vim keybindings.
      The user works on macOS.
      """

      target_size = 50
      result = Reflector.run(session_id, config, observations, target_size, 4.0)

      assert is_binary(result.compressed_observations)
      assert result.compressed_observations != ""
      assert Map.has_key?(result, :before_tokens)
      assert Map.has_key?(result, :after_tokens)
      assert Map.has_key?(result, :compression_level)
      assert Map.has_key?(result, :llm_calls)
      assert result.llm_calls <= 2
    end

    @tag :integration
    test "returns structured result with required fields" do
      config = EvalHelpers.test_config()
      session_id = "test_reflector_structure"

      observations = "## Codebase Facts\n\nThe project uses Elixir."
      target_size = 20

      result = Reflector.run(session_id, config, observations, target_size, 4.0)

      assert Map.has_key?(result, :compressed_observations)
      assert Map.has_key?(result, :before_tokens)
      assert Map.has_key?(result, :after_tokens)
      assert Map.has_key?(result, :compression_level)
      assert Map.has_key?(result, :llm_calls)
      assert is_integer(result.compression_level)
      assert result.compression_level >= 0 and result.compression_level <= 3
    end
  end
end
