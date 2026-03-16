defmodule Deft.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Deft.Tools.Write
  alias Deft.Tool.Context
  alias Deft.Message.Text

  @tmp_dir "/tmp/deft_write_test_#{System.unique_integer([:positive])}"

  setup do
    # Clean up any existing test directory
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    context = %Context{
      working_dir: @tmp_dir,
      session_id: "test-session",
      emit: fn _msg -> :ok end,
      file_scope: nil
    }

    {:ok, context: context}
  end

  describe "name/0" do
    test "returns 'write'" do
      assert Write.name() == "write"
    end
  end

  describe "description/0" do
    test "returns a description" do
      desc = Write.description()
      assert is_binary(desc)
      assert String.contains?(desc, "file")
    end
  end

  describe "parameters/0" do
    test "returns valid JSON Schema" do
      params = Write.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["required"] == ["file_path", "content"]
      assert params["properties"]["file_path"]["type"] == "string"
      assert params["properties"]["content"]["type"] == "string"
    end
  end

  describe "execute/2" do
    test "writes content to a new file", %{context: context} do
      args = %{
        "file_path" => "test.txt",
        "content" => "Hello, world!"
      }

      assert {:ok, [%Text{text: result}]} = Write.execute(args, context)
      assert result =~ "Wrote 13 bytes to test.txt"

      # Verify file was created
      file_path = Path.join(@tmp_dir, "test.txt")
      assert File.exists?(file_path)
      assert File.read!(file_path) == "Hello, world!"
    end

    test "overwrites existing file", %{context: context} do
      file_path = Path.join(@tmp_dir, "existing.txt")
      File.write!(file_path, "old content")

      args = %{
        "file_path" => "existing.txt",
        "content" => "new content"
      }

      assert {:ok, [%Text{text: result}]} = Write.execute(args, context)
      assert result =~ "Wrote 11 bytes to existing.txt"
      assert File.read!(file_path) == "new content"
    end

    test "creates parent directories automatically", %{context: context} do
      args = %{
        "file_path" => "deeply/nested/path/file.txt",
        "content" => "content"
      }

      assert {:ok, [%Text{}]} = Write.execute(args, context)

      file_path = Path.join(@tmp_dir, "deeply/nested/path/file.txt")
      assert File.exists?(file_path)
      assert File.read!(file_path) == "content"
    end

    test "handles absolute paths", %{context: context} do
      absolute_path = Path.join(@tmp_dir, "absolute.txt")

      args = %{
        "file_path" => absolute_path,
        "content" => "absolute content"
      }

      assert {:ok, [%Text{text: result}]} = Write.execute(args, context)
      assert result =~ "Wrote 16 bytes"
      assert File.exists?(absolute_path)
      assert File.read!(absolute_path) == "absolute content"
    end

    test "returns correct byte count for empty content", %{context: context} do
      args = %{
        "file_path" => "empty.txt",
        "content" => ""
      }

      assert {:ok, [%Text{text: result}]} = Write.execute(args, context)
      assert result =~ "Wrote 0 bytes to empty.txt"

      file_path = Path.join(@tmp_dir, "empty.txt")
      assert File.exists?(file_path)
      assert File.read!(file_path) == ""
    end

    test "returns correct byte count for multi-byte UTF-8 content", %{context: context} do
      content = "Hello 世界 🌍"

      args = %{
        "file_path" => "unicode.txt",
        "content" => content
      }

      assert {:ok, [%Text{text: result}]} = Write.execute(args, context)
      # "Hello 世界 🌍" is 17 bytes (not 11 characters)
      expected_bytes = byte_size(content)
      assert result =~ "Wrote #{expected_bytes} bytes to unicode.txt"
    end

    test "returns error when write fails due to permissions" do
      # Create a directory where we can't write
      read_only_dir = Path.join(@tmp_dir, "readonly")
      File.mkdir_p!(read_only_dir)
      File.chmod!(read_only_dir, 0o444)

      context = %Context{
        working_dir: read_only_dir,
        session_id: "test-session",
        emit: fn _msg -> :ok end,
        file_scope: nil
      }

      args = %{
        "file_path" => "forbidden.txt",
        "content" => "content"
      }

      assert {:error, error_msg} = Write.execute(args, context)
      assert error_msg =~ "Failed to"

      # Cleanup
      File.chmod!(read_only_dir, 0o755)
    end
  end

  describe "file scope enforcement" do
    test "allows write when file is within scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => Path.join(scope_dir, "file.txt"),
        "content" => "allowed content"
      }

      assert {:ok, [%Text{}]} = Write.execute(args, context)
      assert File.exists?(Path.join(scope_dir, "file.txt"))
    end

    test "rejects write when file is outside scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)

      outside_dir = Path.join(@tmp_dir, "forbidden")
      File.mkdir_p!(outside_dir)

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => Path.join(outside_dir, "file.txt"),
        "content" => "forbidden content"
      }

      assert {:error, "path outside file scope"} = Write.execute(args, context)
      refute File.exists?(Path.join(outside_dir, "file.txt"))
    end

    test "allows write to subdirectories within scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => Path.join([scope_dir, "sub", "deep", "file.txt"]),
        "content" => "deep content"
      }

      assert {:ok, [%Text{}]} = Write.execute(args, context)
      assert File.exists?(Path.join([scope_dir, "sub", "deep", "file.txt"]))
    end

    test "handles multiple scope paths", %{context: base_context} do
      scope1 = Path.join(@tmp_dir, "scope1")
      scope2 = Path.join(@tmp_dir, "scope2")
      File.mkdir_p!(scope1)
      File.mkdir_p!(scope2)

      context = %{base_context | file_scope: [scope1, scope2]}

      # Should allow write to scope1
      args1 = %{
        "file_path" => Path.join(scope1, "file1.txt"),
        "content" => "content1"
      }

      assert {:ok, [%Text{}]} = Write.execute(args1, context)

      # Should allow write to scope2
      args2 = %{
        "file_path" => Path.join(scope2, "file2.txt"),
        "content" => "content2"
      }

      assert {:ok, [%Text{}]} = Write.execute(args2, context)
    end
  end
end
