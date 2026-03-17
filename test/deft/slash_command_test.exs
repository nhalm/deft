defmodule Deft.SlashCommandTest do
  use ExUnit.Case, async: false

  alias Deft.SlashCommand
  alias Deft.Skills.Registry

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Start the Skills Registry if not already started
    case Process.whereis(Deft.Skills.Registry) do
      nil ->
        {:ok, _pid} = Registry.start_link(project_dir: tmp_dir)

      _pid ->
        :ok
    end

    # Create test skills and commands
    setup_test_fixtures(tmp_dir)

    # Re-scan to pick up test files
    Registry.rescan_project(tmp_dir)

    :ok
  end

  defp setup_test_fixtures(tmp_dir) do
    # Create .deft directory structure
    skills_dir = Path.join([tmp_dir, ".deft", "skills"])
    commands_dir = Path.join([tmp_dir, ".deft", "commands"])
    File.mkdir_p!(skills_dir)
    File.mkdir_p!(commands_dir)

    # Create a test skill with definition
    skill_with_def_path = Path.join(skills_dir, "test-skill.yaml")

    skill_with_def_content = """
    name: test-skill
    description: A test skill with definition
    version: "1.0"

    ---

    You are performing a test task.
    Follow these instructions carefully.
    """

    File.write!(skill_with_def_path, skill_with_def_content)

    # Create a skill without definition (manifest-only)
    skill_no_def_path = Path.join(skills_dir, "no-def.yaml")

    skill_no_def_content = """
    name: no-def
    description: A skill without definition
    version: "1.0"
    """

    File.write!(skill_no_def_path, skill_no_def_content)

    # Create a test command
    command_path = Path.join(commands_dir, "test-command.md")

    command_content = """
    This is a test command.
    It should be injected as a user message.
    """

    File.write!(command_path, command_content)
  end

  describe "parse/1" do
    test "parses slash command with no args" do
      assert SlashCommand.parse("/review") == {:command, "review", ""}
    end

    test "parses slash command with args" do
      assert SlashCommand.parse("/commit --amend") == {:command, "commit", "--amend"}
    end

    test "parses slash command with multiple args" do
      assert SlashCommand.parse("/test foo bar baz") == {:command, "test", "foo bar baz"}
    end

    test "handles leading/trailing whitespace" do
      assert SlashCommand.parse("  /review  ") == {:command, "review", ""}
      assert SlashCommand.parse("  /commit --amend  ") == {:command, "commit", "--amend"}
    end

    test "returns :not_slash for regular text" do
      assert SlashCommand.parse("regular text") == {:not_slash, "regular text"}
    end

    test "returns :not_slash for text with slash in middle" do
      assert SlashCommand.parse("this has a / in middle") ==
               {:not_slash, "this has a / in middle"}
    end

    test "handles single slash as command with empty name" do
      assert SlashCommand.parse("/") == {:command, "", ""}
    end
  end

  describe "dispatch/1" do
    test "dispatches skill with definition" do
      assert {:ok, :skill, definition} = SlashCommand.dispatch("test-skill")
      assert definition =~ "You are performing a test task"
      assert definition =~ "Follow these instructions carefully"
      # Should not include YAML frontmatter
      refute definition =~ "name: test-skill"
    end

    test "dispatches command" do
      assert {:ok, :command, definition} = SlashCommand.dispatch("test-command")
      assert definition =~ "This is a test command"
      assert definition =~ "It should be injected as a user message"
    end

    test "returns error for non-existent command" do
      assert {:error, :not_found, "nonexistent"} = SlashCommand.dispatch("nonexistent")
    end

    test "returns error for skill without definition" do
      assert {:error, :no_definition, "no-def"} = SlashCommand.dispatch("no-def")
    end
  end

  describe "integration: parse + dispatch" do
    test "end-to-end skill invocation" do
      {:command, name, _args} = SlashCommand.parse("/test-skill")
      assert {:ok, :skill, definition} = SlashCommand.dispatch(name)
      assert definition =~ "You are performing a test task"
    end

    test "end-to-end command invocation" do
      {:command, name, _args} = SlashCommand.parse("/test-command")
      assert {:ok, :command, definition} = SlashCommand.dispatch(name)
      assert definition =~ "This is a test command"
    end

    test "end-to-end error handling" do
      {:command, name, _args} = SlashCommand.parse("/nonexistent")
      assert {:error, :not_found, "nonexistent"} = SlashCommand.dispatch(name)
    end
  end
end
