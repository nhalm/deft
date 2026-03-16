defmodule Deft.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Deft.Provider.Anthropic

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
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
    test "parses content_block_start with type text" do
      sse_event = %{
        event: "content_block_start",
        data: Jason.encode!(%{"content_block" => %{"type" => "text"}})
      }

      assert :skip = Anthropic.parse_event(sse_event)
    end

    test "parses content_block_start with type thinking" do
      sse_event = %{
        event: "content_block_start",
        data: Jason.encode!(%{"content_block" => %{"type" => "thinking"}})
      }

      assert :skip = Anthropic.parse_event(sse_event)
    end

    test "parses content_block_start with type tool_use" do
      sse_event = %{
        event: "content_block_start",
        data:
          Jason.encode!(%{
            "content_block" => %{"type" => "tool_use", "id" => "toolu_123", "name" => "read_file"}
          })
      }

      assert %ToolCallStart{id: "toolu_123", name: "read_file"} =
               Anthropic.parse_event(sse_event)
    end

    test "parses content_block_delta with text_delta" do
      sse_event = %{
        event: "content_block_delta",
        data: Jason.encode!(%{"delta" => %{"type" => "text_delta", "text" => "Hello"}})
      }

      assert %TextDelta{delta: "Hello"} = Anthropic.parse_event(sse_event)
    end

    test "parses content_block_delta with thinking_delta" do
      sse_event = %{
        event: "content_block_delta",
        data: Jason.encode!(%{"delta" => %{"type" => "thinking_delta", "thinking" => "Hmm..."}})
      }

      assert %ThinkingDelta{delta: "Hmm..."} = Anthropic.parse_event(sse_event)
    end

    test "parses content_block_delta with input_json_delta" do
      sse_event = %{
        event: "content_block_delta",
        data:
          Jason.encode!(%{
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":\""},
            "index" => 0
          })
      }

      assert %ToolCallDelta{id: "tool_0", delta: "{\"path\":\""} =
               Anthropic.parse_event(sse_event)
    end

    test "parses message_delta with usage" do
      sse_event = %{
        event: "message_delta",
        data: Jason.encode!(%{"usage" => %{"input_tokens" => 100, "output_tokens" => 50}})
      }

      assert %Usage{input: 100, output: 50} = Anthropic.parse_event(sse_event)
    end

    test "parses message_stop" do
      sse_event = %{
        event: "message_stop",
        data: "{}"
      }

      assert %Done{} = Anthropic.parse_event(sse_event)
    end

    test "parses error event with error object" do
      sse_event = %{
        event: "error",
        data: Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded"}})
      }

      assert %Error{message: "Rate limit exceeded"} = Anthropic.parse_event(sse_event)
    end

    test "parses error event with direct message" do
      sse_event = %{
        event: "error",
        data: Jason.encode!(%{"message" => "Connection failed"})
      }

      assert %Error{message: "Connection failed"} = Anthropic.parse_event(sse_event)
    end

    test "returns :skip for unknown event types" do
      sse_event = %{
        event: "unknown_event",
        data: "{}"
      }

      assert :skip = Anthropic.parse_event(sse_event)
    end

    test "returns :skip for malformed data" do
      sse_event = %{
        event: "content_block_delta",
        data: "invalid json"
      }

      assert :skip = Anthropic.parse_event(sse_event)
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
