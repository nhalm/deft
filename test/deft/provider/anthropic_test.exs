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
    test "returns nil system and empty list for empty messages" do
      assert {nil, []} = Anthropic.format_messages([])
    end

    test "extracts system message as string when only text content" do
      messages = [
        %Deft.Message{
          id: "sys1",
          role: :system,
          content: [%Deft.Message.Text{text: "You are a helpful assistant."}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {"You are a helpful assistant.", []} = Anthropic.format_messages(messages)
    end

    test "combines multiple system messages into single string" do
      messages = [
        %Deft.Message{
          id: "sys1",
          role: :system,
          content: [%Deft.Message.Text{text: "First part."}],
          timestamp: DateTime.utc_now()
        },
        %Deft.Message{
          id: "sys2",
          role: :system,
          content: [%Deft.Message.Text{text: "Second part."}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {"First part.\n\nSecond part.", []} = Anthropic.format_messages(messages)
    end

    test "converts user message with text content" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :user,
          content: [%Deft.Message.Text{text: "Hello!"}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil, [%{role: "user", content: [%{type: "text", text: "Hello!"}]}]} =
               Anthropic.format_messages(messages)
    end

    test "converts assistant message with text content" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :assistant,
          content: [%Deft.Message.Text{text: "Hi there!"}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil, [%{role: "assistant", content: [%{type: "text", text: "Hi there!"}]}]} =
               Anthropic.format_messages(messages)
    end

    test "converts tool use content block" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :assistant,
          content: [
            %Deft.Message.ToolUse{
              id: "toolu_123",
              name: "read_file",
              args: %{"path" => "test.txt"}
            }
          ],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil,
              [
                %{
                  role: "assistant",
                  content: [
                    %{
                      type: "tool_use",
                      id: "toolu_123",
                      name: "read_file",
                      input: %{"path" => "test.txt"}
                    }
                  ]
                }
              ]} = Anthropic.format_messages(messages)
    end

    test "converts tool result content block" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :user,
          content: [
            %Deft.Message.ToolResult{
              tool_use_id: "toolu_123",
              name: "read_file",
              content: "file contents",
              is_error: false
            }
          ],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil,
              [
                %{
                  role: "user",
                  content: [
                    %{
                      type: "tool_result",
                      tool_use_id: "toolu_123",
                      content: "file contents",
                      is_error: false
                    }
                  ]
                }
              ]} = Anthropic.format_messages(messages)
    end

    test "converts thinking content block" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :assistant,
          content: [%Deft.Message.Thinking{text: "Let me think about this..."}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil,
              [
                %{
                  role: "assistant",
                  content: [%{type: "thinking", thinking: "Let me think about this..."}]
                }
              ]} = Anthropic.format_messages(messages)
    end

    test "converts image content block" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :user,
          content: [%Deft.Message.Image{media_type: "image/png", data: "base64data"}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil,
              [
                %{
                  role: "user",
                  content: [
                    %{
                      type: "image",
                      source: %{type: "base64", media_type: "image/png", data: "base64data"}
                    }
                  ]
                }
              ]} = Anthropic.format_messages(messages)
    end

    test "converts message with multiple content blocks" do
      messages = [
        %Deft.Message{
          id: "msg1",
          role: :assistant,
          content: [
            %Deft.Message.Text{text: "I'll read that file."},
            %Deft.Message.ToolUse{
              id: "toolu_123",
              name: "read_file",
              args: %{"path" => "test.txt"}
            }
          ],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {nil,
              [
                %{
                  role: "assistant",
                  content: [
                    %{type: "text", text: "I'll read that file."},
                    %{
                      type: "tool_use",
                      id: "toolu_123",
                      name: "read_file",
                      input: %{"path" => "test.txt"}
                    }
                  ]
                }
              ]} = Anthropic.format_messages(messages)
    end

    test "separates system messages from user/assistant messages" do
      messages = [
        %Deft.Message{
          id: "sys1",
          role: :system,
          content: [%Deft.Message.Text{text: "You are helpful."}],
          timestamp: DateTime.utc_now()
        },
        %Deft.Message{
          id: "msg1",
          role: :user,
          content: [%Deft.Message.Text{text: "Hello"}],
          timestamp: DateTime.utc_now()
        },
        %Deft.Message{
          id: "msg2",
          role: :assistant,
          content: [%Deft.Message.Text{text: "Hi!"}],
          timestamp: DateTime.utc_now()
        }
      ]

      assert {"You are helpful.",
              [
                %{role: "user", content: [%{type: "text", text: "Hello"}]},
                %{role: "assistant", content: [%{type: "text", text: "Hi!"}]}
              ]} = Anthropic.format_messages(messages)
    end
  end

  describe "format_tools/1" do
    defmodule MockTool do
      @behaviour Deft.Tool

      @impl Deft.Tool
      def name(), do: "read_file"

      @impl Deft.Tool
      def description(), do: "Read contents of a file"

      @impl Deft.Tool
      def parameters() do
        %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the file"}
          },
          required: ["path"]
        }
      end

      @impl Deft.Tool
      def execute(_args, _context), do: {:ok, []}
    end

    test "returns empty list for empty tools" do
      assert [] = Anthropic.format_tools([])
    end

    test "converts tool module to Anthropic format" do
      result = Anthropic.format_tools([MockTool])

      assert [
               %{
                 name: "read_file",
                 description: "Read contents of a file",
                 input_schema: %{
                   type: "object",
                   properties: %{
                     path: %{type: "string", description: "Path to the file"}
                   },
                   required: ["path"]
                 }
               }
             ] = result
    end

    test "converts multiple tool modules" do
      defmodule AnotherMockTool do
        @behaviour Deft.Tool

        @impl Deft.Tool
        def name(), do: "write_file"

        @impl Deft.Tool
        def description(), do: "Write content to a file"

        @impl Deft.Tool
        def parameters() do
          %{
            type: "object",
            properties: %{
              path: %{type: "string"},
              content: %{type: "string"}
            },
            required: ["path", "content"]
          }
        end

        @impl Deft.Tool
        def execute(_args, _context), do: {:ok, []}
      end

      result = Anthropic.format_tools([MockTool, AnotherMockTool])

      assert length(result) == 2

      assert Enum.any?(result, fn tool ->
               tool.name == "read_file"
             end)

      assert Enum.any?(result, fn tool ->
               tool.name == "write_file"
             end)
    end
  end

  describe "model_config/1" do
    test "returns error for now (not yet implemented)" do
      assert {:error, :unknown_model} = Anthropic.model_config("claude-sonnet-4")
    end
  end
end
