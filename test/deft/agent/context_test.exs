defmodule Deft.Agent.ContextTest do
  use ExUnit.Case, async: true

  alias Deft.Agent.Context
  alias Deft.Message
  alias Deft.Message.Text

  @moduletag :tmp_dir

  describe "build/2" do
    test "returns message list with system prompt, conversation, and no project context when files don't exist",
         %{
           tmp_dir: tmp_dir
         } do
      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should have: system prompt + conversation history (no project context)
      assert length(result) == 2

      # First message is system prompt
      assert [system_msg | _rest] = result
      assert system_msg.role == :system
      assert system_msg.id == "sys_prompt"

      # Second message is the user message
      assert Enum.at(result, 1) == user_message
    end

    test "includes project context from DEFT.md when it exists", %{tmp_dir: tmp_dir} do
      deft_content = "# Project: Deft\n\nProject instructions here."
      File.write!(Path.join(tmp_dir, "DEFT.md"), deft_content)

      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should have: system prompt + conversation + project context
      assert length(result) == 3

      # Last message should be project context
      project_msg = List.last(result)
      assert project_msg.role == :system
      assert project_msg.id == "project_context"
      assert [%Text{text: ^deft_content}] = project_msg.content
    end

    test "includes project context from CLAUDE.md when DEFT.md doesn't exist", %{
      tmp_dir: tmp_dir
    } do
      claude_content = "Claude instructions here."
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), claude_content)

      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should have: system prompt + conversation + project context
      assert length(result) == 3

      # Last message should be project context
      project_msg = List.last(result)
      assert project_msg.role == :system
      assert project_msg.id == "project_context"
      assert [%Text{text: ^claude_content}] = project_msg.content
    end

    test "includes project context from AGENTS.md when DEFT.md and CLAUDE.md don't exist", %{
      tmp_dir: tmp_dir
    } do
      agents_content = "Agent guidelines here."
      File.write!(Path.join(tmp_dir, "AGENTS.md"), agents_content)

      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should have: system prompt + conversation + project context
      assert length(result) == 3

      # Last message should be project context
      project_msg = List.last(result)
      assert project_msg.role == :system
      assert project_msg.id == "project_context"
      assert [%Text{text: ^agents_content}] = project_msg.content
    end

    test "follows reference in CLAUDE.md to AGENTS.md", %{tmp_dir: tmp_dir} do
      agents_content = "Agent guidelines from AGENTS.md"
      File.write!(Path.join(tmp_dir, "AGENTS.md"), agents_content)
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "AGENTS.md\n")

      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should have: system prompt + conversation + project context
      assert length(result) == 3

      # Last message should contain the content from AGENTS.md
      project_msg = List.last(result)
      assert project_msg.role == :system
      assert project_msg.id == "project_context"
      assert [%Text{text: ^agents_content}] = project_msg.content
    end

    test "prefers DEFT.md over CLAUDE.md", %{tmp_dir: tmp_dir} do
      deft_content = "DEFT instructions"
      claude_content = "CLAUDE instructions"
      File.write!(Path.join(tmp_dir, "DEFT.md"), deft_content)
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), claude_content)

      config = %{working_dir: tmp_dir}
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: config)

      # Should use DEFT.md, not CLAUDE.md
      project_msg = List.last(result)
      assert [%Text{text: ^deft_content}] = project_msg.content
    end

    test "preserves conversation history with multiple messages", %{tmp_dir: tmp_dir} do
      config = %{working_dir: tmp_dir}

      messages = [
        create_user_message("First message"),
        create_assistant_message("First response"),
        create_user_message("Second message")
      ]

      result = Context.build(messages, config: config)

      # System prompt + 3 conversation messages
      assert length(result) == 4

      # Verify conversation messages are in order after system prompt
      assert Enum.at(result, 1) == Enum.at(messages, 0)
      assert Enum.at(result, 2) == Enum.at(messages, 1)
      assert Enum.at(result, 3) == Enum.at(messages, 2)
    end

    test "uses current working directory when config doesn't specify working_dir" do
      # This test runs in the project directory which has AGENTS.md
      user_message = create_user_message("Hello")

      result = Context.build([user_message], config: %{})

      # Should find AGENTS.md or CLAUDE.md in current directory
      # The exact file depends on the project setup
      assert length(result) >= 2
    end
  end

  # Helper functions
  defp create_user_message(text) do
    %Message{
      id: "msg_#{:rand.uniform(100_000)}",
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  defp create_assistant_message(text) do
    %Message{
      id: "msg_#{:rand.uniform(100_000)}",
      role: :assistant,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end
end
