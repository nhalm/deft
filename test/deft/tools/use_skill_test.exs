defmodule Deft.Tools.UseSkillTest do
  use ExUnit.Case, async: false

  alias Deft.Tools.UseSkill
  alias Deft.Tool.Context
  alias Deft.Skills.Registry

  @moduletag :tmp_dir

  setup do
    # Start the Skills Registry if not already started
    case Process.whereis(Deft.Skills.Registry) do
      nil ->
        {:ok, _pid} = Registry.start_link()

      _pid ->
        :ok
    end

    :ok
  end

  describe "name/0" do
    test "returns the tool name" do
      assert UseSkill.name() == "use_skill"
    end
  end

  describe "description/0" do
    test "returns a description" do
      desc = UseSkill.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end
  end

  describe "parameters/0" do
    test "defines name parameter" do
      params = UseSkill.parameters()

      assert params["type"] == "object"
      assert params["required"] == ["name"]
      assert params["properties"]["name"]["type"] == "string"
    end
  end

  describe "execute/2" do
    setup %{tmp_dir: tmp_dir} do
      # Create a test skill file in .deft/skills/
      skills_dir = Path.join([tmp_dir, ".deft", "skills"])
      File.mkdir_p!(skills_dir)

      skill_path = Path.join(skills_dir, "test-skill.yaml")

      skill_content = """
      name: test-skill
      description: A test skill
      version: "1.0"

      ---

      This is the skill definition.
      You should follow these instructions.
      """

      File.write!(skill_path, skill_content)

      # Create a skill without definition (manifest-only)
      no_def_path = Path.join(skills_dir, "no-definition.yaml")

      no_def_content = """
      name: no-definition
      description: A skill without definition
      version: "1.0"
      """

      File.write!(no_def_path, no_def_content)

      # Re-scan to pick up test skills
      Registry.rescan_project(tmp_dir)

      context = %Context{
        working_dir: tmp_dir,
        session_id: "test_session",
        emit: fn _text -> :ok end,
        bash_timeout: 120_000
      }

      %{context: context}
    end

    test "loads and returns skill definition", %{context: context} do
      args = %{"name" => "test-skill"}

      assert {:ok, [%Deft.Message.Text{text: text}]} = UseSkill.execute(args, context)
      assert text =~ "This is the skill definition"
      assert text =~ "You should follow these instructions"
      # Should not include the YAML frontmatter
      refute text =~ "name: test-skill"
    end

    test "returns error for non-existent skill", %{context: context} do
      args = %{"name" => "nonexistent"}

      assert {:error, error_msg} = UseSkill.execute(args, context)
      assert error_msg =~ "not found"
      assert error_msg =~ "nonexistent"
    end

    test "returns error for skill without definition", %{context: context} do
      args = %{"name" => "no-definition"}

      assert {:error, error_msg} = UseSkill.execute(args, context)
      assert error_msg =~ "no definition"
      assert error_msg =~ "manifest-only"
    end
  end

  describe "Tool behaviour compliance" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Deft.Tools.UseSkill)
      assert function_exported?(Deft.Tools.UseSkill, :name, 0)
      assert function_exported?(Deft.Tools.UseSkill, :description, 0)
      assert function_exported?(Deft.Tools.UseSkill, :parameters, 0)
      assert function_exported?(Deft.Tools.UseSkill, :execute, 2)
    end
  end
end
