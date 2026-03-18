defmodule Deft.Eval.Lead.TaskPlanningHelpersTest do
  @moduledoc """
  Unit tests for Lead task planning eval helper functions.
  These tests validate the helper logic without making expensive LLM calls.
  """

  use ExUnit.Case, async: true

  alias Deft.Eval.LeadHelpers

  describe "all_have_done_states?/1" do
    test "returns true when all tasks have done states" do
      tasks = [
        %{
          "description" => "Implement user schema",
          "done_state" => "Schema file exists with correct fields"
        },
        %{
          "description" => "Add validation",
          "done_state" => "Tests pass for valid and invalid inputs"
        }
      ]

      assert LeadHelpers.all_have_done_states?(tasks)
    end

    test "returns false when done state is missing" do
      tasks = [
        %{
          "description" => "Implement user schema",
          "done_state" => ""
        }
      ]

      refute LeadHelpers.all_have_done_states?(tasks)
    end

    test "returns false when done state is too short" do
      tasks = [
        %{
          "description" => "Implement user schema",
          "done_state" => "Done"
        }
      ]

      refute LeadHelpers.all_have_done_states?(tasks)
    end

    test "returns false when description is too short" do
      tasks = [
        %{
          "description" => "Fix",
          "done_state" => "Tests pass and code is formatted"
        }
      ]

      refute LeadHelpers.all_have_done_states?(tasks)
    end
  end

  describe "has_valid_dependencies?/1" do
    test "returns true for valid dependency chain" do
      tasks = [
        %{"description" => "Task 1", "done_state" => "Complete", "depends_on" => []},
        %{"description" => "Task 2", "done_state" => "Complete", "depends_on" => [0]},
        %{"description" => "Task 3", "done_state" => "Complete", "depends_on" => [0, 1]}
      ]

      assert LeadHelpers.has_valid_dependencies?(tasks)
    end

    test "returns false when dependency index is invalid" do
      tasks = [
        %{"description" => "Task 1", "done_state" => "Complete", "depends_on" => []},
        %{"description" => "Task 2", "done_state" => "Complete", "depends_on" => [5]}
      ]

      refute LeadHelpers.has_valid_dependencies?(tasks)
    end

    test "returns false when dependency refers to later task" do
      tasks = [
        %{"description" => "Task 1", "done_state" => "Complete", "depends_on" => [1]},
        %{"description" => "Task 2", "done_state" => "Complete", "depends_on" => []}
      ]

      refute LeadHelpers.has_valid_dependencies?(tasks)
    end

    test "returns false when dependency refers to self" do
      tasks = [
        %{"description" => "Task 1", "done_state" => "Complete", "depends_on" => []},
        %{"description" => "Task 2", "done_state" => "Complete", "depends_on" => [1]}
      ]

      refute LeadHelpers.has_valid_dependencies?(tasks)
    end
  end

  describe "validate_tasks/2" do
    test "passes when task count and properties are valid" do
      tasks = [
        %{
          "description" => "Create migration",
          "done_state" => "Migration file exists in priv/repo/migrations",
          "depends_on" => []
        },
        %{
          "description" => "Update schema",
          "done_state" => "Schema has status field",
          "depends_on" => [0]
        },
        %{
          "description" => "Add validation",
          "done_state" => "Changeset validates status field",
          "depends_on" => [1]
        },
        %{
          "description" => "Write tests",
          "done_state" => "Tests pass for all status values",
          "depends_on" => [2]
        }
      ]

      expected = %{
        min_tasks: 4,
        max_tasks: 8,
        has_dependencies: true,
        has_done_states: true
      }

      result = LeadHelpers.validate_tasks(tasks, expected)
      assert result.passed
      assert is_nil(result.reason)
    end

    test "fails when too few tasks" do
      tasks = [
        %{
          "description" => "Do something",
          "done_state" => "It's done when complete",
          "depends_on" => []
        }
      ]

      expected = %{min_tasks: 4, max_tasks: 8}
      result = LeadHelpers.validate_tasks(tasks, expected)
      refute result.passed
      assert result.reason =~ "Too few tasks"
    end

    test "fails when too many tasks" do
      tasks =
        Enum.map(1..10, fn i ->
          %{
            "description" => "Task #{i}",
            "done_state" => "Done when complete #{i}",
            "depends_on" => []
          }
        end)

      expected = %{min_tasks: 4, max_tasks: 8}
      result = LeadHelpers.validate_tasks(tasks, expected)
      refute result.passed
      assert result.reason =~ "Too many tasks"
    end

    test "fails when done states are missing" do
      tasks = [
        %{"description" => "Task 1", "done_state" => "", "depends_on" => []},
        %{"description" => "Task 2", "done_state" => "Done", "depends_on" => []},
        %{"description" => "Task 3", "done_state" => "Complete", "depends_on" => []},
        %{"description" => "Task 4", "done_state" => "Finished", "depends_on" => []}
      ]

      expected = %{min_tasks: 4, max_tasks: 8}
      result = LeadHelpers.validate_tasks(tasks, expected)
      refute result.passed
      assert result.reason =~ "done states"
    end

    test "fails when dependencies are invalid" do
      tasks = [
        %{
          "description" => "Task 1",
          "done_state" => "Complete when done",
          "depends_on" => []
        },
        %{
          "description" => "Task 2",
          "done_state" => "Complete when done",
          "depends_on" => []
        },
        %{
          "description" => "Task 3",
          "done_state" => "Complete when done",
          "depends_on" => []
        },
        %{
          "description" => "Task 4",
          "done_state" => "Complete when done",
          "depends_on" => [10]
        }
      ]

      expected = %{min_tasks: 4, max_tasks: 8}
      result = LeadHelpers.validate_tasks(tasks, expected)
      refute result.passed
      assert result.reason =~ "dependency"
    end
  end

  describe "extract_json/1" do
    test "extracts JSON from code block" do
      text = """
      Here's the task list:

      ```json
      {
        "tasks": [
          {"description": "Task 1", "done_state": "Done", "depends_on": []}
        ]
      }
      ```
      """

      {:ok, data} = LeadHelpers.extract_json(text)
      assert is_map(data)
      assert Map.has_key?(data, "tasks")
    end

    test "extracts raw JSON" do
      text = """
      {"tasks": [{"description": "Task 1", "done_state": "Done", "depends_on": []}]}
      """

      {:ok, data} = LeadHelpers.extract_json(text)
      assert is_map(data)
      assert Map.has_key?(data, "tasks")
    end

    test "extracts JSON when preceded by text" do
      text = """
      Here is my response:

      {"tasks": [{"description": "Task 1", "done_state": "Done", "depends_on": []}]}
      """

      {:ok, data} = LeadHelpers.extract_json(text)
      assert is_map(data)
      assert Map.has_key?(data, "tasks")
    end

    test "returns error for invalid JSON" do
      text = "This is not JSON"
      {:error, reason} = LeadHelpers.extract_json(text)
      assert is_binary(reason)
    end
  end
end
