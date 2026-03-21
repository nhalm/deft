defmodule Deft.Eval.Observer.PriorityTest do
  @moduledoc """
  Eval tests for Observer read vs modified tracking.

  Tests that the Observer correctly distinguishes between files that were
  READ vs files that were MODIFIED, with relevant detail about what changed.

  This tests the scenario: agent reads a file, then later modifies it.
  The observations should track both events and distinguish them clearly.

  Pass rate: 80% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Eval.Helpers
  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.80

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "read vs modified tracking - LLM judge (80% over 20 iterations)" do
    @tag timeout: 180_000
    test "distinguishes file read from file modification", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # First: read the file
          read_messages = [
            build_tool_result_message("""
            File: lib/user.ex

            defmodule MyApp.User do
              defstruct [:name, :email]
            end
            """)
          ]

          read_result = Observer.run(config, read_messages, "", 4.0)

          # Then: modify the file
          edit_messages = [
            build_edit_tool_call_message("lib/user.ex", "Add age field")
          ]

          final_result = Observer.run(config, edit_messages, read_result.observations, 4.0)

          # Judge: Do observations distinguish read from modification?
          judge_read_vs_modified(final_result.observations, "lib/user.ex")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nRead vs modified tracking: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "tracks modification details in Files & Architecture", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Read then modify with specific change
          read_messages = [
            build_tool_result_message("""
            File: lib/auth.ex

            defmodule MyApp.Auth do
              def login(email, password) do
                # TODO: implement
              end
            end
            """)
          ]

          read_result = Observer.run(config, read_messages, "", 4.0)

          edit_messages = [
            build_edit_tool_call_message(
              "lib/auth.ex",
              "Implement login with Bcrypt password verification"
            )
          ]

          final_result = Observer.run(config, edit_messages, read_result.observations, 4.0)

          # Judge: Do observations mention what was changed?
          judge_modification_details(
            final_result.observations,
            "lib/auth.ex",
            "Bcrypt"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nModification detail tracking: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "tracks multiple files with mixed read/modify operations", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Complex scenario: read A, read B, modify A, read C
          messages = [
            build_tool_result_message("File: lib/user.ex\n\ndefmodule User do\nend"),
            build_tool_result_message("File: lib/auth.ex\n\ndefmodule Auth do\nend"),
            build_edit_tool_call_message("lib/user.ex", "Add email field"),
            build_tool_result_message("File: lib/session.ex\n\ndefmodule Session do\nend")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Observations should show user.ex was modified, others read
          judge_mixed_operations(result.observations, [
            {"lib/user.ex", :modified},
            {"lib/auth.ex", :read},
            {"lib/session.ex", :read}
          ])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nMixed operations tracking: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "tracks file creation separately from modification", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Create a new file (Write tool)
          messages = [
            build_write_tool_call_message(
              "lib/new_module.ex",
              "Create new module with User schema"
            )
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Should indicate file was created/written, not just modified
          judge_file_creation(result.observations, "lib/new_module.ex")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nFile creation tracking: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build a tool result message (for Read tool)
  defp build_tool_result_message(text) do
    %Message{
      id: generate_id(),
      role: :user,
      content: [
        %Deft.Message.ToolResult{
          tool_use_id: generate_id(),
          name: "Read",
          content: text,
          is_error: false
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build an Edit tool call message
  defp build_edit_tool_call_message(file_path, description) do
    %Message{
      id: generate_id(),
      role: :assistant,
      content: [
        %Deft.Message.ToolUse{
          id: generate_id(),
          name: "Edit",
          args: %{
            "file_path" => file_path,
            "old_string" => "...",
            "new_string" => description
          }
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build a Write tool call message
  defp build_write_tool_call_message(file_path, description) do
    %Message{
      id: generate_id(),
      role: :assistant,
      content: [
        %Deft.Message.ToolUse{
          id: generate_id(),
          name: "Write",
          args: %{
            "file_path" => file_path,
            "content" => description
          }
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Helper: Judge that observations distinguish read from modified
  defp judge_read_vs_modified(observations, file_path) do
    prompt = """
    You are checking if observation notes correctly distinguish between reading and modifying a file.

    OBSERVATIONS:
    #{observations}

    FILE: #{file_path}

    EXPECTED: The file was first READ, then later MODIFIED.

    QUESTION: Do the observations clearly distinguish between these two operations?

    Good tracking should indicate:
    - That the file was read (e.g., "Read #{file_path}")
    - That the file was later modified/edited (e.g., "Modified #{file_path}", "Edited #{file_path}")
    - The distinction should be clear (not just "accessed" or "used")

    Respond with ONLY one word:
    - "PASS" if observations clearly distinguish read from modification
    - "FAIL" if observations don't distinguish or only mention one operation

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Helper: Judge that modification details are captured
  defp judge_modification_details(observations, file_path, expected_detail) do
    prompt = """
    You are checking if observation notes capture modification details.

    OBSERVATIONS:
    #{observations}

    FILE: #{file_path}
    EXPECTED DETAIL: #{expected_detail}

    QUESTION: Do the observations mention what was changed in #{file_path}, specifically
    including reference to "#{expected_detail}"?

    Respond with ONLY one word:
    - "PASS" if observations mention the modification and include "#{expected_detail}"
    - "FAIL" if observations don't mention what changed or miss "#{expected_detail}"

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Helper: Judge mixed operations tracking
  defp judge_mixed_operations(observations, file_operations) do
    # Build prompt checking each file's expected operation
    operations_text =
      Enum.map_join(file_operations, "\n", fn {file, op} ->
        "- #{file}: should be marked as #{op}"
      end)

    prompt = """
    You are checking if observation notes correctly track multiple file operations.

    OBSERVATIONS:
    #{observations}

    EXPECTED OPERATIONS:
    #{operations_text}

    QUESTION: Do the observations correctly indicate which files were read vs modified?

    Respond with ONLY one word:
    - "PASS" if all operations are correctly tracked
    - "FAIL" if any operation is incorrectly tracked or missing

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Helper: Judge file creation tracking
  defp judge_file_creation(observations, file_path) do
    prompt = """
    You are checking if observation notes correctly indicate file creation.

    OBSERVATIONS:
    #{observations}

    FILE: #{file_path}

    EXPECTED: This file was newly CREATED (using Write tool), not modified.

    QUESTION: Do the observations indicate this was a new file creation (not just modification)?

    Good indicators: "Created #{file_path}", "Wrote #{file_path}", "New file #{file_path}"
    Not as good: "Modified #{file_path}", "Edited #{file_path}" (implies existing file)

    Respond with ONLY one word:
    - "PASS" if observations indicate file creation/writing
    - "FAIL" if observations don't capture this or incorrectly say "modified"

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end
end
