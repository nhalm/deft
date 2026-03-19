defmodule Deft.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Deft.Tools.Edit
  alias Deft.Tool.Context
  alias Deft.Message.Text

  @tmp_dir "/tmp/deft_edit_test_#{System.unique_integer([:positive])}"

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
      file_scope: nil,
      bash_timeout: 120_000
    }

    {:ok, context: context}
  end

  describe "name/0" do
    test "returns 'edit'" do
      assert Edit.name() == "edit"
    end
  end

  describe "description/0" do
    test "returns a description" do
      desc = Edit.description()
      assert is_binary(desc)
      assert String.contains?(desc, "edit") or String.contains?(desc, "Edit")
    end
  end

  describe "parameters/0" do
    test "returns valid JSON Schema" do
      params = Edit.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["required"] == ["file_path"]
      assert params["properties"]["file_path"]["type"] == "string"
      assert params["properties"]["old_string"]["type"] == "string"
      assert params["properties"]["new_string"]["type"] == "string"
      assert params["properties"]["start_line"]["type"] == "integer"
      assert params["properties"]["end_line"]["type"] == "integer"
      assert params["properties"]["new_content"]["type"] == "string"
    end
  end

  describe "string-match mode" do
    test "replaces unique string match", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Hello world\nThis is a test\nGoodbye world")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "This is a test",
        "new_string" => "This is modified"
      }

      assert {:ok, [%Text{text: result}]} = Edit.execute(args, context)
      assert result =~ "---"
      assert result =~ "+++"
      assert result =~ "-This is a test"
      assert result =~ "+This is modified"

      # Verify file was modified
      assert File.read!(file_path) == "Hello world\nThis is modified\nGoodbye world"
    end

    test "returns error when string not found", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Hello world\nThis is a test")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "nonexistent string",
        "new_string" => "replacement"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "String not found"
    end

    test "returns error when string appears multiple times", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "foo bar\nfoo baz\nfoo qux")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "foo",
        "new_string" => "bar"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "appears 3 times"
      assert error_msg =~ "must be unique"
    end

    test "provides similar text suggestions when string not found", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Hello world\nThis is a test\nGoodbye world")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "This is test",
        "new_string" => "replacement"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "String not found"
      # Should suggest similar lines containing "This" or "is" or "test"
      assert error_msg =~ "Did you mean"
    end

    test "handles multi-line string replacements", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3\nLine 4")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "Line 2\nLine 3",
        "new_string" => "Modified Line 2\nModified Line 3"
      }

      assert {:ok, [%Text{text: result}]} = Edit.execute(args, context)
      assert result =~ "---"
      assert result =~ "+++"

      assert File.read!(file_path) == "Line 1\nModified Line 2\nModified Line 3\nLine 4"
    end

    test "handles empty string replacement", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Hello DELETE_ME world")

      args = %{
        "file_path" => "test.txt",
        "old_string" => "DELETE_ME ",
        "new_string" => ""
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "Hello world"
    end
  end

  describe "line-range mode" do
    test "replaces line range", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 2,
        "end_line" => 4,
        "new_content" => "New Line 2\nNew Line 3\nNew Line 4"
      }

      assert {:ok, [%Text{text: result}]} = Edit.execute(args, context)
      assert result =~ "---"
      assert result =~ "+++"

      assert File.read!(file_path) == "Line 1\nNew Line 2\nNew Line 3\nNew Line 4\nLine 5"
    end

    test "replaces single line", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 2,
        "end_line" => 2,
        "new_content" => "Modified Line 2"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "Line 1\nModified Line 2\nLine 3"
    end

    test "deletes lines by replacing with empty content", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3\nLine 4")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 2,
        "end_line" => 3,
        "new_content" => ""
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "Line 1\nLine 4"
    end

    test "replaces first line", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 1,
        "end_line" => 1,
        "new_content" => "Modified Line 1"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "Modified Line 1\nLine 2\nLine 3"
    end

    test "replaces last line", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 3,
        "end_line" => 3,
        "new_content" => "Modified Line 3"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "Line 1\nLine 2\nModified Line 3"
    end

    test "returns error when start_line > end_line", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 3,
        "end_line" => 1,
        "new_content" => "content"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "start_line"
      assert error_msg =~ "end_line"
    end

    test "returns error when line numbers are < 1", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 0,
        "end_line" => 2,
        "new_content" => "content"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ ">= 1"
    end

    test "returns error when end_line exceeds file length", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      args = %{
        "file_path" => "test.txt",
        "start_line" => 1,
        "end_line" => 10,
        "new_content" => "content"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "exceeds file length"
      assert error_msg =~ "3 lines"
    end
  end

  describe "common validations" do
    test "returns error when file not found", %{context: context} do
      args = %{
        "file_path" => "nonexistent.txt",
        "old_string" => "foo",
        "new_string" => "bar"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "File not found"
    end

    test "returns error when path is a directory", %{context: context} do
      dir_path = Path.join(@tmp_dir, "subdir")
      File.mkdir_p!(dir_path)

      args = %{
        "file_path" => "subdir",
        "old_string" => "foo",
        "new_string" => "bar"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "directory"
    end

    test "returns error when neither mode is properly specified", %{context: context} do
      file_path = Path.join(@tmp_dir, "test.txt")
      File.write!(file_path, "content")

      args = %{
        "file_path" => "test.txt"
      }

      assert {:error, error_msg} = Edit.execute(args, context)
      assert error_msg =~ "Must provide either"
    end

    test "handles absolute paths", %{context: context} do
      file_path = Path.join(@tmp_dir, "absolute.txt")
      File.write!(file_path, "foo bar")

      args = %{
        "file_path" => file_path,
        "old_string" => "foo",
        "new_string" => "baz"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "baz bar"
    end
  end

  describe "file scope enforcement" do
    test "allows edit when file is within scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)
      file_path = Path.join(scope_dir, "file.txt")
      File.write!(file_path, "old content")

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => file_path,
        "old_string" => "old",
        "new_string" => "new"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(file_path) == "new content"
    end

    test "rejects edit when file is outside scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)

      outside_dir = Path.join(@tmp_dir, "forbidden")
      File.mkdir_p!(outside_dir)
      file_path = Path.join(outside_dir, "file.txt")
      File.write!(file_path, "old content")

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => file_path,
        "old_string" => "old",
        "new_string" => "new"
      }

      assert {:error, "path outside file scope"} = Edit.execute(args, context)
      assert File.read!(file_path) == "old content"
    end

    test "allows edit to subdirectories within scope", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)
      deep_path = Path.join([scope_dir, "sub", "deep", "file.txt"])
      File.mkdir_p!(Path.dirname(deep_path))
      File.write!(deep_path, "old content")

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => deep_path,
        "old_string" => "old",
        "new_string" => "new"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args, context)
      assert File.read!(deep_path) == "new content"
    end

    test "handles multiple scope paths", %{context: base_context} do
      scope1 = Path.join(@tmp_dir, "scope1")
      scope2 = Path.join(@tmp_dir, "scope2")
      File.mkdir_p!(scope1)
      File.mkdir_p!(scope2)

      file1 = Path.join(scope1, "file1.txt")
      file2 = Path.join(scope2, "file2.txt")
      File.write!(file1, "content1")
      File.write!(file2, "content2")

      context = %{base_context | file_scope: [scope1, scope2]}

      # Should allow edit to scope1
      args1 = %{
        "file_path" => file1,
        "old_string" => "content1",
        "new_string" => "modified1"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args1, context)
      assert File.read!(file1) == "modified1"

      # Should allow edit to scope2
      args2 = %{
        "file_path" => file2,
        "old_string" => "content2",
        "new_string" => "modified2"
      }

      assert {:ok, [%Text{}]} = Edit.execute(args2, context)
      assert File.read!(file2) == "modified2"
    end

    test "file scope applies to line-range mode too", %{context: base_context} do
      scope_dir = Path.join(@tmp_dir, "allowed")
      File.mkdir_p!(scope_dir)

      outside_dir = Path.join(@tmp_dir, "forbidden")
      File.mkdir_p!(outside_dir)
      file_path = Path.join(outside_dir, "file.txt")
      File.write!(file_path, "Line 1\nLine 2\nLine 3")

      context = %{base_context | file_scope: [scope_dir]}

      args = %{
        "file_path" => file_path,
        "start_line" => 1,
        "end_line" => 2,
        "new_content" => "Modified"
      }

      assert {:error, "path outside file scope"} = Edit.execute(args, context)
      assert File.read!(file_path) == "Line 1\nLine 2\nLine 3"
    end
  end
end
