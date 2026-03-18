defmodule Deft.Tools.IssueDraft do
  @moduledoc """
  Tool for creating structured issue drafts during interactive elicitation.

  This tool is used by the issue elicitation agent to output a structured
  JSON draft of the issue being created. The CLI parses this tool call result
  and presents it for user confirmation.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "issue_draft"

  @impl Deft.Tool
  def description do
    "Create a structured issue draft with title, context, acceptance criteria, constraints, and priority. " <>
      "Use this tool to finalize the issue after gathering information from the user."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" => "One-line summary of the issue"
        },
        "context" => %{
          "type" => "string",
          "description" => "What and why — background, motivation, relevant details"
        },
        "acceptance_criteria" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of concrete conditions that define 'done'"
        },
        "constraints" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Implementation constraints (e.g., 'use argon2', 'don't change public API')"
        },
        "priority" => %{
          "type" => "integer",
          "description" => "Priority level: 0=critical, 1=high, 2=medium, 3=low, 4=backlog",
          "minimum" => 0,
          "maximum" => 4
        }
      },
      "required" => ["title", "context", "acceptance_criteria", "constraints", "priority"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{}) do
    # Validate the input
    with :ok <- validate_title(args["title"]),
         :ok <- validate_context(args["context"]),
         :ok <- validate_acceptance_criteria(args["acceptance_criteria"]),
         :ok <- validate_constraints(args["constraints"]),
         :ok <- validate_priority(args["priority"]) do
      # Return the draft as JSON in a special marker format that the CLI can parse
      draft_json = Jason.encode!(args)
      result_text = "ISSUE_DRAFT:#{draft_json}"

      {:ok, [%Text{text: result_text}]}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_title(title) when is_binary(title) and byte_size(title) > 0, do: :ok
  defp validate_title(_), do: {:error, "Title must be a non-empty string"}

  defp validate_context(context) when is_binary(context), do: :ok
  defp validate_context(_), do: {:error, "Context must be a string"}

  defp validate_acceptance_criteria(criteria) when is_list(criteria), do: :ok
  defp validate_acceptance_criteria(_), do: {:error, "Acceptance criteria must be a list"}

  defp validate_constraints(constraints) when is_list(constraints), do: :ok
  defp validate_constraints(_), do: {:error, "Constraints must be a list"}

  defp validate_priority(priority) when is_integer(priority) and priority in 0..4, do: :ok
  defp validate_priority(_), do: {:error, "Priority must be an integer between 0 and 4"}
end
