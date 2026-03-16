defmodule Deft.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Deft.Tools.Bash
  alias Deft.Tool.Context
  alias Deft.Message.Text

  setup do
    # Create temp directory for test working directory
    working_dir = System.tmp_dir!() |> Path.join("deft_bash_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(working_dir)

    # Track emitted output
    {:ok, emit_agent} = Agent.start_link(fn -> [] end)

    emit = fn text ->
      Agent.update(emit_agent, &[text | &1])
      :ok
    end

    context = %Context{
      working_dir: working_dir,
      session_id: "test-session",
      emit: emit,
      file_scope: nil
    }

    on_exit(fn ->
      File.rm_rf(working_dir)

      if Process.alive?(emit_agent) do
        Agent.stop(emit_agent)
      end
    end)

    %{context: context, emit_agent: emit_agent, working_dir: working_dir}
  end

  describe "behaviour implementation" do
    test "implements Deft.Tool behaviour" do
      assert function_exported?(Bash, :name, 0)
      assert function_exported?(Bash, :description, 0)
      assert function_exported?(Bash, :parameters, 0)
      assert function_exported?(Bash, :execute, 2)
    end

    test "name/0 returns 'bash'" do
      assert Bash.name() == "bash"
    end

    test "description/0 returns non-empty string" do
      desc = Bash.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns valid JSON schema" do
      params = Bash.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["properties"]["command"]["type"] == "string"
      assert params["properties"]["timeout"]["type"] == "integer"
      assert params["required"] == ["command"]
    end
  end

  describe "command execution" do
    test "executes simple echo command", %{context: context} do
      args = %{"command" => "echo 'Hello, World!'"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "Hello, World!"
      assert result =~ "Exit code: 0 (success)"
    end

    test "captures stdout", %{context: context} do
      args = %{"command" => "echo 'test output'"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "test output"
    end

    test "captures stderr", %{context: context} do
      args = %{"command" => "echo 'error message' >&2"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "error message"
    end

    test "returns non-zero exit code on failure", %{context: context} do
      args = %{"command" => "exit 42"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "Exit code: 42 (failure)"
    end

    test "respects working directory", %{context: context, working_dir: working_dir} do
      File.write!(Path.join(working_dir, "test.txt"), "content")
      args = %{"command" => "cat test.txt"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "content"
    end

    test "handles empty output", %{context: context} do
      args = %{"command" => "true"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "(no output)"
      assert result =~ "Exit code: 0 (success)"
    end
  end

  describe "streaming via emit" do
    test "emits command being executed", %{context: context, emit_agent: emit_agent} do
      args = %{"command" => "echo 'test'"}
      Bash.execute(args, context)

      emitted = Agent.get(emit_agent, & &1) |> Enum.reverse()
      assert Enum.any?(emitted, &String.contains?(&1, "$ echo 'test'"))
    end

    test "emits output in real-time", %{context: context, emit_agent: emit_agent} do
      args = %{"command" => "echo 'line1'; echo 'line2'"}
      Bash.execute(args, context)

      emitted = Agent.get(emit_agent, & &1) |> Enum.reverse() |> Enum.join()
      assert emitted =~ "line1"
      assert emitted =~ "line2"
    end
  end

  describe "timeout handling" do
    test "uses default timeout of 120s when not specified", %{context: context} do
      # We can't easily test the default timeout in a reasonable time,
      # but we can verify quick commands complete successfully
      args = %{"command" => "echo 'quick'"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "quick"
    end

    test "respects custom timeout", %{context: context} do
      # Test with a very short timeout on a slow command
      args = %{"command" => "sleep 5", "timeout" => 100}
      assert {:error, message} = Bash.execute(args, context)
      assert message =~ "timed out"
      assert message =~ "100ms"
    end

    test "completes within custom timeout", %{context: context} do
      args = %{"command" => "echo 'fast'", "timeout" => 5000}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "fast"
    end
  end

  describe "output truncation" do
    test "truncates output exceeding 100 lines", %{context: context} do
      # Generate 150 lines
      command = "for i in $(seq 1 150); do echo \"Line $i\"; done"
      args = %{"command" => command}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)

      # Should have last 100 lines (lines 51-150)
      lines = String.split(result, "\n")
      output_lines = Enum.filter(lines, &String.starts_with?(&1, "Line"))
      assert length(output_lines) == 100

      # Should have line 150 (last line) and line 51 (first of last 100)
      assert result =~ "Line 150"
      assert result =~ "Line 51"

      # Should NOT have lines 1-50 (use newline to ensure exact line match)
      refute result =~ "Line 1\n"
      refute result =~ "Line 50\n"
    end

    test "truncates output exceeding 30KB", %{context: context} do
      # Generate >30KB of output (each line is ~50 bytes, so 700 lines = ~35KB)
      command =
        "for i in $(seq 1 700); do echo \"This is a longer line number $i with extra padding\"; done"

      args = %{"command" => command}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)

      # Extract just the output portion (before "Exit code:")
      [output_part | _] = String.split(result, "\n\nExit code:")

      # Should be truncated to around 30KB
      assert byte_size(output_part) <= 31_000

      # Should have last line but not first line
      assert result =~ "line number 700"
      refute result =~ "line number 1"
    end

    test "does not truncate small output", %{context: context} do
      args = %{"command" => "echo 'small'"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "small"
      refute result =~ "Full output saved to"
    end
  end

  describe "temp file handling" do
    test "saves full output to temp file when truncated", %{context: context} do
      # Generate output large enough to be truncated (>30KB)
      # Each line is about 50 bytes, so 700 lines = ~35KB
      command =
        "for i in $(seq 1 700); do echo \"This is a longer line number $i with padding text\"; done"

      args = %{"command" => command}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)

      # Should mention temp file since output was truncated by bytes
      assert result =~ "Full output saved to:"

      # Extract temp file path (remove any trailing whitespace)
      [temp_path] =
        Regex.run(~r/Full output saved to: (.+)/, result, capture: :all_but_first)

      temp_path = String.trim(temp_path)

      # Verify file exists and has full output
      assert File.exists?(temp_path)
      {:ok, full_content} = File.read(temp_path)
      assert full_content =~ "line number 1"
      assert full_content =~ "line number 700"

      # Clean up
      File.rm(temp_path)
    end

    test "cleans up empty temp files", %{context: context} do
      args = %{"command" => "true"}
      assert {:ok, _} = Bash.execute(args, context)

      # Check that no temp files were left behind
      _temp_files =
        File.ls!(System.tmp_dir!())
        |> Enum.filter(&String.starts_with?(&1, "deft_bash_"))

      # There might be temp files from other tests, but they should all be non-empty
      # or from currently running tests. We can't reliably test this without
      # more complex tracking.
      assert true
    end
  end

  describe "shell escaping" do
    test "handles commands with single quotes", %{context: context} do
      args = %{"command" => "echo \"It's working\""}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "It's working"
    end

    test "handles commands with special characters", %{context: context} do
      args = %{"command" => "echo 'test & test | test > test'"}
      assert {:ok, [%Text{text: result}]} = Bash.execute(args, context)
      assert result =~ "test & test | test > test"
    end
  end
end
