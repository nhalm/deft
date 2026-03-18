defmodule Deft.Skills.RegistryTest do
  use ExUnit.Case, async: false

  # Note: These tests use the global Deft.Skills.Registry started by the Application.
  # In test environment, the registry will be mostly empty since test fixtures aren't
  # in the standard paths. This is intentional - we're testing the API, not mocking discovery.

  alias Deft.Skills.Entry

  @moduletag :skills

  describe "list/0" do
    test "returns a list of entries" do
      entries = Deft.Skills.Registry.list()
      assert is_list(entries)

      # Each entry should be a valid Entry struct
      Enum.each(entries, fn entry ->
        assert %Entry{} = entry
        assert is_binary(entry.name)
        assert entry.type in [:skill, :command]
        assert entry.level in [:builtin, :global, :project]
        assert is_binary(entry.path)
        assert is_boolean(entry.loaded)
      end)
    end

    test "returns entries sorted by name" do
      entries = Deft.Skills.Registry.list()
      names = Enum.map(entries, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "lookup/1" do
    test "returns :not_found for non-existent entry" do
      assert Deft.Skills.Registry.lookup("nonexistent-skill-" <> __MODULE__.UUID.uuid4()) ==
               :not_found
    end

    test "returns entry for existing skill if any exist" do
      case Deft.Skills.Registry.list() do
        [] ->
          # No skills in test environment, skip
          :ok

        [entry | _rest] ->
          looked_up = Deft.Skills.Registry.lookup(entry.name)
          assert looked_up != :not_found
          assert looked_up.name == entry.name
      end
    end
  end

  describe "load_definition/1" do
    test "returns error for non-existent entry" do
      result =
        Deft.Skills.Registry.load_definition("nonexistent-skill-" <> __MODULE__.UUID.uuid4())

      assert {:error, :not_found} = result
    end

    test "loads definition for existing entry if any exist" do
      case Deft.Skills.Registry.list() do
        [] ->
          # No skills in test environment, skip
          :ok

        [entry | _rest] ->
          # Try to load definition
          result = Deft.Skills.Registry.load_definition(entry.name)

          # Result should be either {:ok, definition}, {:error, :no_definition}, or {:error, :enoent}
          # (for manifest-only skills or missing definition files)
          case result do
            {:ok, definition} ->
              assert is_binary(definition)

            {:error, :no_definition} ->
              # This is valid for manifest-only skills
              :ok

            {:error, :enoent} ->
              # This is valid when the definition file doesn't exist
              :ok

            other ->
              flunk("Unexpected result: #{inspect(other)}")
          end
      end
    end
  end

  describe "rescan_project/1" do
    setup do
      # Create a temporary directory for project fixtures
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{__MODULE__.UUID.uuid4()}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "rescans project skills and commands", %{tmp_dir: tmp_dir} do
      # Create initial project skills and commands
      skills_dir = Path.join([tmp_dir, ".deft", "skills"])
      commands_dir = Path.join([tmp_dir, ".deft", "commands"])
      File.mkdir_p!(skills_dir)
      File.mkdir_p!(commands_dir)

      # Write initial skill
      File.write!(
        Path.join(skills_dir, "test-skill.yaml"),
        """
        name: test-skill
        description: Initial test skill
        version: "1.0"

        ---

        This is the initial test skill definition.
        """
      )

      # Write initial command
      File.write!(
        Path.join(commands_dir, "test-command.md"),
        "This is a test command."
      )

      # First scan
      Deft.Skills.Registry.rescan_project(tmp_dir)

      # Verify initial state
      skill_entry = Deft.Skills.Registry.lookup("test-skill")
      command_entry = Deft.Skills.Registry.lookup("test-command")

      assert %Entry{name: "test-skill", type: :skill, level: :project} = skill_entry
      assert %Entry{name: "test-command", type: :command, level: :project} = command_entry

      # Modify the project: remove command, update skill description, add new skill
      File.rm!(Path.join(commands_dir, "test-command.md"))

      File.write!(
        Path.join(skills_dir, "test-skill.yaml"),
        """
        name: test-skill
        description: Updated test skill
        version: "2.0"

        ---

        This is the updated test skill definition.
        """
      )

      File.write!(
        Path.join(skills_dir, "new-skill.yaml"),
        """
        name: new-skill
        description: Brand new skill
        version: "1.0"

        ---

        Brand new skill definition.
        """
      )

      # Rescan
      Deft.Skills.Registry.rescan_project(tmp_dir)

      # Verify changes
      updated_skill = Deft.Skills.Registry.lookup("test-skill")
      new_skill = Deft.Skills.Registry.lookup("new-skill")
      removed_command = Deft.Skills.Registry.lookup("test-command")

      assert %Entry{
               name: "test-skill",
               type: :skill,
               level: :project,
               description: "Updated test skill"
             } = updated_skill

      assert %Entry{name: "new-skill", type: :skill, level: :project} = new_skill
      assert removed_command == :not_found
    end

    test "preserves non-project entries during rescan", %{tmp_dir: tmp_dir} do
      # Get current non-project entries
      initial_entries = Deft.Skills.Registry.list()
      non_project_count = Enum.count(initial_entries, &(&1.level != :project))

      # Create project skill
      skills_dir = Path.join([tmp_dir, ".deft", "skills"])
      File.mkdir_p!(skills_dir)

      File.write!(
        Path.join(skills_dir, "project-only.yaml"),
        """
        name: project-only
        description: Project-specific skill
        version: "1.0"

        ---

        Project skill definition.
        """
      )

      # Rescan with project directory
      Deft.Skills.Registry.rescan_project(tmp_dir)

      # Verify non-project entries are unchanged
      after_scan = Deft.Skills.Registry.list()
      after_non_project_count = Enum.count(after_scan, &(&1.level != :project))

      assert after_non_project_count == non_project_count

      # Verify project entry was added
      assert %Entry{name: "project-only", level: :project} =
               Deft.Skills.Registry.lookup("project-only")

      # Clean up by rescanning with empty project dir
      File.rm_rf!(Path.join(tmp_dir, ".deft"))
      Deft.Skills.Registry.rescan_project(tmp_dir)

      # Verify project entry was removed but non-project entries still exist
      final_entries = Deft.Skills.Registry.list()
      final_non_project_count = Enum.count(final_entries, &(&1.level != :project))

      assert final_non_project_count == non_project_count
      assert Deft.Skills.Registry.lookup("project-only") == :not_found
    end

    test "handles empty project directory", %{tmp_dir: tmp_dir} do
      # Create and then remove project directory
      deft_dir = Path.join(tmp_dir, ".deft")
      File.mkdir_p!(deft_dir)

      # Rescan with empty project
      Deft.Skills.Registry.rescan_project(tmp_dir)

      # Should succeed without errors
      entries = Deft.Skills.Registry.list()
      project_entries = Enum.filter(entries, &(&1.level == :project))

      assert project_entries == []
    end
  end

  # UUID helper for generating unique test names
  defmodule UUID do
    def uuid4 do
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)
    end
  end
end
