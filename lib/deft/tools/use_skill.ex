defmodule Deft.Tools.UseSkill do
  @moduledoc """
  Tool for agent-initiated skill invocation.

  Allows the agent to auto-invoke skills when contextually appropriate.
  The agent emits a use_skill tool call with the skill name, and the harness
  loads the full definition from the Skills Registry and injects it into context.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Skills.Registry
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "use_skill"

  @impl Deft.Tool
  def description do
    "Invoke a skill by name. The skill's full definition will be loaded and executed. " <>
      "Use this when a skill is contextually appropriate for the current task."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "The name of the skill to invoke"
        }
      },
      "required" => ["name"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{}) do
    skill_name = args["name"]

    case Registry.load_definition(skill_name) do
      {:ok, definition} ->
        {:ok, [%Text{text: definition}]}

      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_name}"}

      {:error, :no_definition} ->
        {:error,
         "Skill '#{skill_name}' exists but has no definition (manifest-only, missing --- separator)"}

      {:error, reason} ->
        {:error, "Failed to load skill '#{skill_name}': #{inspect(reason)}"}
    end
  end
end
