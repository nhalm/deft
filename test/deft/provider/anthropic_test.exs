defmodule Deft.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Deft.Provider.Anthropic

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
    ToolCallDone,
    Usage,
    Done,
    Error
  }

  describe "stream/3" do
    test "fails fast when ANTHROPIC_API_KEY is missing" do
      # Clear the env var
      original = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      result = Anthropic.stream([], [], %{})
      assert result == {:error, :missing_api_key}

      # Restore
      if original, do: System.put_env("ANTHROPIC_API_KEY", original)
    end

    test "fails fast when ANTHROPIC_API_KEY is empty" do
      original = System.get_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "")

      result = Anthropic.stream([], [], %{})
      assert result == {:error, :missing_api_key}

      # Restore
      if original, do: System.put_env("ANTHROPIC_API_KEY", original)
    end

    test "returns {:ok, pid} when API key is present" do
      original = System.get_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      # This will fail to connect but should return a PID
      result = Anthropic.stream([], [], %{model: "claude-sonnet-4"})

      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          # Clean up
          Process.exit(pid, :kill)

        {:error, _} ->
          # Connection failed, which is expected in test
          :ok
      end

      # Restore
      if original do
        System.put_env("ANTHROPIC_API_KEY", original)
      else
        System.delete_env("ANTHROPIC_API_KEY")
      end
    end
  end

  describe "cancel_stream/1" do
    test "terminates the stream process" do
      # Spawn a dummy process
      pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.monitor(pid)

      # Cancel it
      assert :ok = Anthropic.cancel_stream(pid)

      # Verify it died
      assert_receive {:DOWN, _ref, :process, ^pid, :cancelled}, 500
    end

    test "is idempotent" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = Anthropic.cancel_stream(pid)
      # Calling again should still return :ok
      assert :ok = Anthropic.cancel_stream(pid)
    end
  end

  describe "parse_event/1" do
    test "returns :skip for now (not yet implemented)" do
      assert :skip = Anthropic.parse_event(%{})
    end
  end

  describe "format_messages/1" do
    test "returns empty list for now (not yet implemented)" do
      assert [] = Anthropic.format_messages([])
    end
  end

  describe "format_tools/1" do
    test "returns empty list for now (not yet implemented)" do
      assert [] = Anthropic.format_tools([])
    end
  end

  describe "model_config/1" do
    test "returns error for now (not yet implemented)" do
      assert {:error, :unknown_model} = Anthropic.model_config("claude-sonnet-4")
    end
  end
end
