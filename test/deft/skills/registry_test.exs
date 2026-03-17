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

          # Result should be either {:ok, definition} or {:error, :no_definition}
          # (for manifest-only skills)
          case result do
            {:ok, definition} ->
              assert is_binary(definition)

            {:error, :no_definition} ->
              # This is valid for manifest-only skills
              :ok

            other ->
              flunk("Unexpected result: #{inspect(other)}")
          end
      end
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
