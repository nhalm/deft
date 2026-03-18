defmodule Deft.EvalHelpers do
  @moduledoc """
  Helper functions for eval tests.
  """

  alias Deft.{Config, Message}
  alias Deft.Message.{Text, ToolUse, ToolResult}

  @doc """
  Creates a basic test config with Observer model settings.
  """
  def test_config do
    # Load default config
    Config.load(%{}, File.cwd!())
  end

  @doc """
  Creates a user message with text content.
  """
  def user_message(text) do
    %Message{
      id: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates an assistant message with text content.
  """
  def assistant_message(text) do
    %Message{
      id: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      role: :assistant,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates an assistant message with a tool use.
  """
  def assistant_tool_use(tool_name, args) do
    %Message{
      id: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      role: :assistant,
      content: [
        %ToolUse{
          id: "toolu_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          name: tool_name,
          args: args
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates a user message with a tool result.
  """
  def user_tool_result(tool_use_id, tool_name, content, is_error \\ false) do
    %Message{
      id: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      role: :user,
      content: [
        %ToolResult{
          tool_use_id: tool_use_id,
          name: tool_name,
          content: content,
          is_error: is_error
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Checks if observations contain all required strings.
  """
  def contains_all?(observations, required_strings) when is_list(required_strings) do
    Enum.all?(required_strings, fn str ->
      String.contains?(observations, str)
    end)
  end

  @doc """
  Checks if observations are routed to the correct section.
  """
  def in_section?(observations, section_name, content) do
    # Split observations into sections
    sections = String.split(observations, ~r/^##\s+/m, trim: true)

    # Find the target section
    target_section =
      Enum.find(sections, fn section ->
        String.starts_with?(section, section_name)
      end)

    case target_section do
      nil -> false
      section -> String.contains?(section, content)
    end
  end
end
