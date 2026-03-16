defmodule Deft.ToolTest do
  use ExUnit.Case, async: true

  alias Deft.Tool
  alias Deft.Tool.Context
  alias Deft.Message

  # Test tool implementation
  defmodule TestTool do
    @behaviour Tool

    @impl Tool
    def name, do: "test_tool"

    @impl Tool
    def description, do: "A test tool for validation"

    @impl Tool
    def parameters do
      %{
        type: "object",
        properties: %{
          input: %{type: "string", description: "Test input"}
        },
        required: ["input"]
      }
    end

    @impl Tool
    def execute(args, context) do
      text = "Executed with input: #{args["input"]} in #{context.working_dir}"
      {:ok, [%Message.Text{text: text}]}
    end
  end

  describe "Tool behaviour" do
    test "can be implemented with all required callbacks" do
      assert TestTool.name() == "test_tool"
      assert TestTool.description() == "A test tool for validation"
      assert is_map(TestTool.parameters())
      assert TestTool.parameters().type == "object"
    end

    test "execute/2 receives args and context" do
      context = %Context{
        working_dir: "/tmp/test",
        session_id: "test-session",
        emit: fn _msg -> :ok end,
        file_scope: nil
      }

      assert {:ok, [%Message.Text{text: text}]} =
               TestTool.execute(%{"input" => "hello"}, context)

      assert text =~ "hello"
      assert text =~ "/tmp/test"
    end
  end

  describe "Tool.Context" do
    test "can be created with required fields" do
      context = %Context{
        working_dir: "/tmp",
        session_id: "sess-123",
        emit: fn _msg -> :ok end
      }

      assert context.working_dir == "/tmp"
      assert context.session_id == "sess-123"
      assert is_function(context.emit, 1)
      assert is_nil(context.file_scope)
    end

    test "supports optional file_scope" do
      context = %Context{
        working_dir: "/tmp",
        session_id: "sess-123",
        emit: fn _msg -> :ok end,
        file_scope: ["lib/", "test/"]
      }

      assert context.file_scope == ["lib/", "test/"]
    end

    test "emit function can be called" do
      test_pid = self()

      context = %Context{
        working_dir: "/tmp",
        session_id: "sess-123",
        emit: fn msg -> send(test_pid, {:emitted, msg}) end
      }

      context.emit.("test message")

      assert_receive {:emitted, "test message"}
    end
  end
end
