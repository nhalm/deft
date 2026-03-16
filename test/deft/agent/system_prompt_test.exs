defmodule Deft.Agent.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Deft.Agent.SystemPrompt

  @moduletag :tmp_dir

  describe "build/1" do
    test "includes role definition" do
      result = SystemPrompt.build(%{})

      assert result =~ "You are Deft"
      assert result =~ "autonomous AI agent"
    end

    test "includes working directory in environment info", %{tmp_dir: tmp_dir} do
      result = SystemPrompt.build(%{working_dir: tmp_dir})

      assert result =~ "**Working Directory:** #{tmp_dir}"
    end

    test "includes current date in environment info" do
      result = SystemPrompt.build(%{})

      # Should include the current year at minimum
      current_year = DateTime.utc_now().year |> to_string()
      assert result =~ current_year
    end

    test "includes OS information in environment info" do
      result = SystemPrompt.build(%{})

      # Should mention OS in some form (macOS, Linux, Windows, etc.)
      assert result =~ "**OS:**"
    end

    test "includes git branch when in a git repository" do
      # Use the current directory which is a git repo
      result = SystemPrompt.build(%{working_dir: File.cwd!()})

      # Should include git branch information (the actual branch name may vary)
      assert result =~ "**Git Branch:**"
    end

    test "handles non-git directory gracefully" do
      # Create a temp directory outside any git repo
      # Since we're in a git repo, we'll just verify the function doesn't crash
      # and includes git information (even if it finds parent repo)
      result = SystemPrompt.build(%{working_dir: "/tmp"})

      # Should not crash and should include git info
      assert result =~ "Git"
    end

    test "includes conflict resolution rules" do
      result = SystemPrompt.build(%{})

      assert result =~ "Conflict Resolution"
      assert result =~ "Project files take precedence"
      assert result =~ "Specs are source of truth"
    end

    test "omits tool section when no tools provided" do
      result = SystemPrompt.build(%{})

      refute result =~ "Available Tools"
    end

    test "includes tool descriptions when tools provided" do
      # Create a mock tool module
      defmodule MockTool do
        def name, do: "mock_tool"
        def description, do: "A mock tool for testing"

        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "arg1" => %{"type" => "string", "description" => "First argument"},
              "arg2" => %{"type" => "integer", "description" => "Second argument"}
            },
            "required" => ["arg1"]
          }
        end
      end

      result = SystemPrompt.build(%{tools: [MockTool]})

      assert result =~ "Available Tools"
      assert result =~ "mock_tool"
      assert result =~ "A mock tool for testing"
      assert result =~ "arg1"
      assert result =~ "(required)"
      assert result =~ "First argument"
      assert result =~ "arg2"
      assert result =~ "Second argument"
    end

    test "handles tool without proper behaviour implementation gracefully" do
      # Create a module that doesn't implement the tool behaviour
      defmodule BrokenTool do
        def name, do: raise("intentional error")
      end

      # Should not crash
      result = SystemPrompt.build(%{tools: [BrokenTool]})

      assert result =~ "Tool definition error"
    end

    test "uses current working directory when not specified" do
      result = SystemPrompt.build(%{})

      # Should include some working directory
      assert result =~ "**Working Directory:**"
    end

    test "handles empty tool parameter schema" do
      defmodule NoParamTool do
        def name, do: "no_param_tool"
        def description, do: "Tool with no parameters"
        def parameters, do: %{}
      end

      result = SystemPrompt.build(%{tools: [NoParamTool]})

      assert result =~ "no_param_tool"
      assert result =~ "Tool with no parameters"
    end
  end
end
