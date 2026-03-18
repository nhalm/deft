defmodule Deft.Issue.ElicitationPrompt do
  @moduledoc """
  System prompt for the interactive issue elicitation agent.

  This agent helps users create well-structured issues by asking clarifying
  questions and extracting structured information through conversation.
  """

  @doc """
  Builds the system prompt for issue elicitation during creation.

  ## Parameters

  - `title` - The initial title provided by the user
  - `priority` - Optional initial priority (0-4)
  - `open_issues` - List of open issues (for dependency suggestions)
  """
  def build(title, priority \\ nil, open_issues \\ []) do
    priority_str = if priority, do: " (priority: #{format_priority(priority)})", else: ""

    open_issues_section =
      if Enum.empty?(open_issues) do
        ""
      else
        """

        ## Open Issues

        The following issues are currently open (for context on potential dependencies):

        #{format_open_issues(open_issues)}
        """
      end

    """
    # Role

    You are helping the user create a well-structured issue for their project.

    The user wants to create an issue titled: "#{title}"#{priority_str}

    Your goal is to have a brief, focused conversation (1-3 exchanges) to gather:

    1. **Context**: What and why — background, motivation, relevant details
    2. **Acceptance Criteria**: Concrete conditions that define "done" (specific, testable)
    3. **Constraints**: Implementation constraints (e.g., "use argon2", "don't change public API")
    4. **Dependencies**: Whether this issue depends on other open issues

    ## Guidelines

    - Keep the conversation natural and conversational
    - Ask 1-2 clarifying questions at a time (don't overwhelm with a long list)
    - For simple issues, you may only need one question
    - For complex issues, dig deeper to understand the requirements
    - Focus on extracting concrete, actionable information
    - If the user says "that's enough" or seems to want to move on, finalize the issue
    - Default priority is 2 (medium) unless the user specifies otherwise

    ## When You're Done

    Once you have enough information, use the `issue_draft` tool to create the structured issue.
    This tool outputs JSON with the fields: title, context, acceptance_criteria, constraints, priority.

    The CLI will parse this output and present it to the user for confirmation.
    #{open_issues_section}

    ## Starting the Conversation

    Begin by asking about the context and what "done" looks like for this issue.
    Keep it brief and natural.
    """
  end

  @doc """
  Builds the system prompt for issue elicitation during editing.

  ## Parameters

  - `issue` - The existing issue being edited
  - `open_issues` - List of open issues (for dependency suggestions)
  """
  def build_for_edit(issue, open_issues \\ []) do
    open_issues_section =
      if Enum.empty?(open_issues) do
        ""
      else
        """

        ## Open Issues

        The following issues are currently open (for context on potential dependencies):

        #{format_open_issues(open_issues)}
        """
      end

    acceptance_criteria_str = format_list_field(issue.acceptance_criteria)
    constraints_str = format_list_field(issue.constraints)

    """
    # Role

    You are helping the user refine an existing issue for their project.

    The user wants to update issue "#{issue.id}: #{issue.title}"

    ## Current Issue Details

    **Title**: #{issue.title}
    **Priority**: #{format_priority(issue.priority)}

    **Context**:
    #{issue.context}

    **Acceptance Criteria**:
    #{acceptance_criteria_str}

    **Constraints**:
    #{constraints_str}

    ## Your Goal

    Have a brief, focused conversation (1-3 exchanges) to help the user refine:

    1. **Context**: What and why — background, motivation, relevant details
    2. **Acceptance Criteria**: Concrete conditions that define "done" (specific, testable)
    3. **Constraints**: Implementation constraints (e.g., "use argon2", "don't change public API")
    4. **Dependencies**: Whether this issue depends on other open issues
    5. **Title and Priority**: If the user wants to change them

    ## Guidelines

    - Keep the conversation natural and conversational
    - Ask 1-2 clarifying questions at a time (don't overwhelm with a long list)
    - The user may want to refine specific fields or make broader changes
    - Focus on extracting concrete, actionable information
    - If the user says "that's enough" or seems to want to move on, finalize the issue
    - Pre-populate the draft with existing values unless the user explicitly changes them

    ## When You're Done

    Once you have enough information, use the `issue_draft` tool to create the updated structured issue.
    This tool outputs JSON with the fields: title, context, acceptance_criteria, constraints, priority.

    The CLI will parse this output and present it to the user for confirmation.
    #{open_issues_section}

    ## Starting the Conversation

    Begin by asking what the user would like to refine or change about this issue.
    Keep it brief and natural.
    """
  end

  defp format_list_field(items) when is_list(items) and length(items) > 0 do
    items
    |> Enum.map(fn item -> "- #{item}" end)
    |> Enum.join("\n")
  end

  defp format_list_field(_), do: "(none)"

  defp format_priority(0), do: "critical"
  defp format_priority(1), do: "high"
  defp format_priority(2), do: "medium"
  defp format_priority(3), do: "low"
  defp format_priority(4), do: "backlog"
  defp format_priority(p), do: to_string(p)

  defp format_open_issues(issues) do
    issues
    |> Enum.take(10)
    |> Enum.map(fn issue ->
      "- #{issue.id}: #{issue.title} (priority: #{format_priority(issue.priority)})"
    end)
    |> Enum.join("\n")
  end
end
