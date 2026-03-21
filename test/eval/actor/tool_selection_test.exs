defmodule Deft.Eval.Actor.ToolSelectionTest do
  @moduledoc """
  Eval tests for Actor tool selection.

  Tests that the Actor correctly selects appropriate tools for different tasks.
  Per spec section 4.3, the actor should:
  - Use `read` for file reading (not `bash cat`)
  - Use `find` for file searching (not `bash find`)
  - Use `grep` for code searching (not `bash grep`)
  - Use `bash` for running commands like tests
  - Use `edit` for file editing (not `bash sed`)

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.Provider.Anthropic
  alias Deft.Provider.Event.{TextDelta, ToolCallStart, Done, Error}

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  setup do
    config = Config.load()

    {:ok, config: config}
  end

  describe "tool selection - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "selects 'read' for file reading", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_tool_request("Read src/auth.ex")

          # Collect tool calls from response
          tool_calls = call_provider_and_collect_tools(messages, config)

          # Judge: Should call 'read' (or 'Read'), not 'bash'
          # Per spec section 4.3, must contain a tool call at all
          has_tool_call?(tool_calls) and uses_read_tool?(tool_calls) and
            not uses_bash_for_reading?(tool_calls)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTool selection (read): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Tool selection below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "selects 'find' for file searching", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_tool_request("Find all test files")

          tool_calls = call_provider_and_collect_tools(messages, config)

          # Judge: Should call 'find' (or 'Glob'), not 'bash'
          has_tool_call?(tool_calls) and uses_find_tool?(tool_calls) and
            not uses_bash_for_finding?(tool_calls)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTool selection (find): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "selects 'grep' for code searching", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_tool_request("Search for 'defmodule Auth' in the codebase")

          tool_calls = call_provider_and_collect_tools(messages, config)

          # Judge: Should call 'grep' (or 'Grep'), not 'bash'
          has_tool_call?(tool_calls) and uses_grep_tool?(tool_calls) and
            not uses_bash_for_grepping?(tool_calls)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTool selection (grep): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "selects 'bash' for running tests", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_tool_request("Run the tests")

          tool_calls = call_provider_and_collect_tools(messages, config)

          # Judge: Should call 'bash' (or 'Bash') for running commands
          has_tool_call?(tool_calls) and uses_bash_tool?(tool_calls)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTool selection (bash for tests): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "selects 'edit' for file editing", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_tool_request("Change foo to bar in config.exs")

          tool_calls = call_provider_and_collect_tools(messages, config)

          # Judge: Should call 'edit' (or 'Edit'), not 'bash'
          has_tool_call?(tool_calls) and uses_edit_tool?(tool_calls) and
            not uses_bash_for_editing?(tool_calls)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTool selection (edit): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build simple tool request message
  defp build_tool_request(prompt) do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant with access to these tools:
          - Read: Read file contents
          - Glob: Find files by pattern
          - Grep: Search code by regex
          - Edit: Edit file contents
          - Bash: Run shell commands

          Use the appropriate tool for each task.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: prompt}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Call provider and collect tool calls
  defp call_provider_and_collect_tools(messages, config) do
    case Anthropic.stream(messages, [], config) do
      {:ok, stream_ref} ->
        collect_tool_calls(stream_ref, [], 60_000)

      {:error, _reason} ->
        []
    end
  end

  # Collect tool calls from stream
  defp collect_tool_calls(stream_ref, tool_calls, timeout) do
    receive do
      {:provider_event, %ToolCallStart{name: name}} ->
        collect_tool_calls(stream_ref, [name | tool_calls], timeout)

      {:provider_event, %TextDelta{}} ->
        collect_tool_calls(stream_ref, tool_calls, timeout)

      {:provider_event, %Done{}} ->
        Enum.reverse(tool_calls)

      {:provider_event, %Error{}} ->
        Enum.reverse(tool_calls)
    after
      timeout ->
        Anthropic.cancel_stream(stream_ref)
        Enum.reverse(tool_calls)
    end
  end

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Judge helpers
  defp has_tool_call?(tool_calls) do
    length(tool_calls) > 0
  end

  defp uses_read_tool?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      String.downcase(name) == "read"
    end)
  end

  defp uses_find_tool?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      downcase = String.downcase(name)
      downcase == "find" or downcase == "glob"
    end)
  end

  defp uses_grep_tool?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      String.downcase(name) == "grep"
    end)
  end

  defp uses_bash_tool?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      String.downcase(name) == "bash"
    end)
  end

  defp uses_edit_tool?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      String.downcase(name) == "edit"
    end)
  end

  defp uses_bash_for_reading?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      downcase = String.downcase(name)
      downcase == "bash" and String.contains?(downcase, "cat")
    end)
  end

  defp uses_bash_for_finding?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      downcase = String.downcase(name)
      downcase == "bash" and String.contains?(downcase, "find")
    end)
  end

  defp uses_bash_for_grepping?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      downcase = String.downcase(name)
      downcase == "bash" and String.contains?(downcase, "grep")
    end)
  end

  defp uses_bash_for_editing?(tool_calls) do
    Enum.any?(tool_calls, fn name ->
      downcase = String.downcase(name)

      downcase == "bash" and
        (String.contains?(downcase, "sed") or String.contains?(downcase, "awk"))
    end)
  end
end
