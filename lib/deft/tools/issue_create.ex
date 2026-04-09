defmodule Deft.Tools.IssueCreate do
  @moduledoc """
  Tool for agents to create issues during any session.

  This tool allows agents to create issues for out-of-scope work they identify,
  such as discovered bugs, needed refactors, TODO items, or follow-up work.

  Agent-created issues have `source: :agent` and default to priority 3 (low),
  but agents may assign higher priority for discovered bugs that affect current
  functionality.
  """

  @behaviour Deft.Tool

  alias Deft.Config
  alias Deft.Issues
  alias Deft.Message.Text
  alias Deft.Tool.Context

  require Logger

  @impl Deft.Tool
  def name, do: "issue_create"

  @impl Deft.Tool
  def description do
    """
    Create a new issue for out-of-scope work discovered during the session.

    Use this tool when you identify work that should be tracked but is not part of
    the current task, such as:
    - Discovered bugs that should be fixed
    - Needed refactors
    - TODO items found in code
    - Follow-up work from the current task

    Do NOT create issues for:
    - The current task itself (already tracked)
    - Trivial observations that don't require action

    Agent-created issues default to priority 3 (low), but you may assign higher
    priority (0-2) for bugs that affect current functionality. Always explain your
    priority choice in the issue context.
    """
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
          "description" =>
            "What and why — background, motivation, relevant details. " <>
              "If you're assigning priority higher than 3 (low), explain why in this field."
        },
        "acceptance_criteria" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of concrete conditions that define 'done'",
          "default" => []
        },
        "constraints" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Implementation constraints (e.g., 'use argon2', 'don't change public API')",
          "default" => []
        },
        "priority" => %{
          "type" => "integer",
          "description" =>
            "Priority level: 0=critical, 1=high, 2=medium, 3=low (default), 4=backlog. " <>
              "Default is 3 (low). Use 0-2 for bugs affecting current functionality.",
          "minimum" => 0,
          "maximum" => 4,
          "default" => 3
        }
      },
      "required" => ["title", "context"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{} = context) do
    with :ok <- validate_title(args["title"]),
         :ok <- validate_context(args["context"]),
         :ok <- validate_acceptance_criteria(args["acceptance_criteria"]),
         :ok <- validate_constraints(args["constraints"]),
         :ok <- validate_priority(args["priority"]) do
      create_issue_and_format_result(args, context)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_issue_and_format_result(args, context) do
    ensure_issues_started(context)
    attrs = build_issue_attrs(args)

    case Issues.create(attrs) do
      {:ok, issue} ->
        result_text = format_success_result(issue)
        Logger.info("Agent created issue #{issue.id}: #{issue.title}")
        {:ok, [%Text{text: String.trim(result_text)}]}

      {:error, reason} ->
        {:error, "Failed to create issue: #{inspect(reason)}"}
    end
  end

  # Build issue attributes with agent source
  # Note: priority defaults to 3 (low) for agent-created issues when not provided
  # This is handled by the GenServer based on source
  defp build_issue_attrs(args) do
    attrs = %{
      title: args["title"],
      context: args["context"],
      acceptance_criteria: args["acceptance_criteria"] || [],
      constraints: args["constraints"] || [],
      source: :agent
    }

    # Only include priority if explicitly provided by agent
    if args["priority"] do
      Map.put(attrs, :priority, args["priority"])
    else
      attrs
    end
  end

  defp format_success_result(issue) do
    """
    Created issue #{issue.id}: #{issue.title}
    Priority: #{priority_name(issue.priority)}
    Status: #{issue.status}

    The issue has been added to the work queue.
    """
  end

  defp validate_title(title) when is_binary(title) and byte_size(title) > 0, do: :ok
  defp validate_title(nil), do: {:error, "Title is required"}
  defp validate_title(_), do: {:error, "Title must be a non-empty string"}

  defp validate_context(context) when is_binary(context) and byte_size(context) > 0, do: :ok
  defp validate_context(nil), do: {:error, "Context is required"}
  defp validate_context(_), do: {:error, "Context must be a non-empty string"}

  defp validate_acceptance_criteria(nil), do: :ok
  defp validate_acceptance_criteria(criteria) when is_list(criteria), do: :ok
  defp validate_acceptance_criteria(_), do: {:error, "Acceptance criteria must be a list"}

  defp validate_constraints(nil), do: :ok
  defp validate_constraints(constraints) when is_list(constraints), do: :ok
  defp validate_constraints(_), do: {:error, "Constraints must be a list"}

  defp validate_priority(nil), do: :ok
  defp validate_priority(priority) when is_integer(priority) and priority in 0..4, do: :ok
  defp validate_priority(_), do: {:error, "Priority must be an integer between 0 and 4"}

  defp priority_name(0), do: "critical"
  defp priority_name(1), do: "high"
  defp priority_name(2), do: "medium"
  defp priority_name(3), do: "low"
  defp priority_name(4), do: "backlog"
  defp priority_name(_), do: "unknown"

  # Ensures the Issues GenServer is running, starting it if necessary
  defp ensure_issues_started(%Context{working_dir: working_dir}) do
    case Process.whereis(Issues) do
      nil ->
        # Not running, start it
        # Load config to get compaction_days setting
        config = Config.load(%{}, working_dir)
        file_path = Path.join([working_dir, ".deft", "issues.jsonl"])

        case Issues.start_link(
               file_path: file_path,
               compaction_days: config.issues_compaction_days
             ) do
          {:ok, _pid} ->
            Logger.debug("Started Issues GenServer from issue_create tool")
            :ok

          {:error, {:already_started, _pid}} ->
            # Race condition: another process started it between check and start
            :ok

          {:error, reason} ->
            Logger.error("Failed to start Issues GenServer: #{inspect(reason)}")
            :ok
        end

      _pid ->
        # Already running
        :ok
    end
  end
end
