defmodule Deft.Eval.Observer.SectionRoutingTest do
  @moduledoc """
  Eval tests for Observer section routing.

  Tests that the Observer correctly routes extracted facts to the appropriate
  sections in the observations output:
  - User preferences → ## User Preferences
  - File operations → ## Files & Architecture
  - Implementation decisions → ## Decisions
  - Current task → ## Current State
  - General events → ## Session History

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "section routing - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "routes user preferences to ## User Preferences", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("I prefer 2-space indentation")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Is the preference in the User Preferences section?
          judge_section_placement(
            result.observations,
            "User Preferences",
            "2-space indentation"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nUser preference routing: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "routes file operations to ## Files & Architecture", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_tool_result_message("""
            File: lib/auth.ex

            defmodule Auth do
              def login(user, password), do: :ok
            end
            """)
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Is the file mentioned in Files & Architecture?
          judge_section_placement(
            result.observations,
            "Files & Architecture",
            "lib/auth.ex"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nFile operation routing: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "routes implementation decisions to ## Decisions", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message(
              "Let's use Ecto for the database layer because it integrates well with Phoenix"
            )
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Is the decision in the Decisions section?
          judge_section_placement(
            result.observations,
            "Decisions",
            "Ecto"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nImplementation decision routing: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "routes current task to ## Current State", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("Now we need to implement user authentication")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Is the task in Current State?
          judge_section_placement(
            result.observations,
            "Current State",
            "authentication"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nCurrent task routing: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "routes general conversation to ## Session History", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("The tests are passing now"),
            build_assistant_message("Great! Should we move on to the next feature?")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Judge: Is the conversation event in Session History?
          judge_section_placement(
            result.observations,
            "Session History",
            "tests"
          )
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nGeneral conversation routing: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build a user message
  defp build_user_message(text) do
    %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build an assistant message
  defp build_assistant_message(text) do
    %Message{
      id: generate_id(),
      role: :assistant,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build a tool result message
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

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Helper: Judge if content appears in the correct section
  defp judge_section_placement(observations, expected_section, content_term) do
    # Parse sections from observations
    sections = parse_sections(observations)

    # Check if the expected section exists and contains the content
    case Map.get(sections, expected_section) do
      nil ->
        false

      section_content ->
        String.downcase(section_content) =~ String.downcase(content_term)
    end
  end

  # Helper: Parse observations into sections
  defp parse_sections(observations) do
    # Split by ## headers
    observations
    |> String.split(~r/^## /m)
    |> Enum.drop(1)
    |> Enum.reduce(%{}, fn section_text, acc ->
      case String.split(section_text, "\n", parts: 2) do
        [title, content] ->
          Map.put(acc, String.trim(title), content)

        _ ->
          acc
      end
    end)
  end
end
