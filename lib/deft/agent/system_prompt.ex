defmodule Deft.Agent.SystemPrompt do
  @moduledoc """
  System prompt builder for the Deft agent.

  Constructs the system prompt that defines the agent's role, capabilities,
  and environment. Per harness spec section 4, the system prompt includes:
  - Role definition
  - Tool descriptions (from registered tools)
  - Working directory
  - Git branch
  - Date and OS
  - Conflict resolution rules
  """

  @doc """
  Builds the system prompt text.

  ## Parameters

  - `config` - Agent configuration map containing:
    - `:working_dir` - Current working directory (optional, defaults to cwd)
    - `:tools` - List of tool modules implementing Deft.Tool behaviour (optional)

  ## Returns

  String containing the complete system prompt.
  """
  def build(config \\ %{}) do
    working_dir = Map.get(config, :working_dir, File.cwd!())
    tools = Map.get(config, :tools, [])
    cache_active = Map.get(config, :cache_active, false)

    [
      build_role_definition(),
      build_tool_descriptions(tools),
      build_cache_spilling_instruction(cache_active),
      build_skills_commands_listing(),
      build_environment_info(working_dir),
      build_conflict_resolution_rules()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Role definition section
  defp build_role_definition do
    """
    # Role

    You are Deft, an autonomous AI agent specialized in software development tasks.

    Your primary capabilities include:
    - Reading and writing code across multiple programming languages
    - Executing shell commands to build, test, and deploy software
    - Searching codebases for files and patterns
    - Analyzing and debugging issues
    - Following project-specific instructions and conventions

    You work autonomously to accomplish tasks while keeping the user informed
    of your progress through observations and status updates.
    """
  end

  # Tool descriptions section
  defp build_tool_descriptions([]), do: nil

  defp build_tool_descriptions(tools) do
    tool_specs =
      tools
      |> Enum.map(&format_tool_description/1)
      |> Enum.join("\n\n")

    """
    # Available Tools

    You have access to the following tools:

    #{tool_specs}

    Use these tools to accomplish your tasks. Always provide complete and accurate
    parameters when calling tools.
    """
  end

  # Format a single tool's description from its behaviour callbacks
  defp format_tool_description(tool_module) do
    name = apply(tool_module, :name, [])
    description = apply(tool_module, :description, [])
    parameters = apply(tool_module, :parameters, [])

    param_spec = format_parameters(parameters)

    """
    ## #{name}

    #{description}

    Parameters:
    #{param_spec}
    """
  rescue
    _exception ->
      # Tool module doesn't implement the behaviour properly
      "## #{inspect(tool_module)}\n\nTool definition error"
  end

  # Format parameter schema
  defp format_parameters(params) when is_map(params) do
    params
    |> Map.get("properties", %{})
    |> Enum.map(fn {param_name, param_info} ->
      required = Map.get(params, "required", []) |> Enum.member?(param_name)
      description = Map.get(param_info, "description", "")
      type = Map.get(param_info, "type", "any")

      required_marker = if required, do: " (required)", else: ""
      "- `#{param_name}` (#{type})#{required_marker}: #{description}"
    end)
    |> Enum.join("\n")
  end

  defp format_parameters(_), do: "No parameters"

  # Cache spilling instruction section
  defp build_cache_spilling_instruction(false), do: nil

  defp build_cache_spilling_instruction(true) do
    """
    # Cache Spilling

    When a tool result contains `Full results: cache://<key>`, the full output is stored in cache. Use the `cache_read` tool to retrieve it when you need details not in the summary. You can filter results: `cache_read(key, filter: 'pattern')` or request specific line ranges: `cache_read(key, lines: '740-760')`.
    """
  end

  # Skills and commands listing section
  defp build_skills_commands_listing do
    entries = Deft.Skills.Registry.list()

    skills =
      entries
      |> Enum.filter(&(&1.type == :skill))
      |> Enum.map(fn entry -> "- /#{entry.name} — #{entry.description}" end)

    commands =
      entries
      |> Enum.filter(&(&1.type == :command))
      |> Enum.map(fn entry ->
        if entry.description do
          "- /#{entry.name} — #{entry.description}"
        else
          "- /#{entry.name}"
        end
      end)

    skills_section =
      if Enum.empty?(skills) do
        nil
      else
        """
        Available skills:
        #{Enum.join(skills, "\n")}
        """
      end

    commands_section =
      if Enum.empty?(commands) do
        nil
      else
        """
        Available commands:
        #{Enum.join(commands, "\n")}
        """
      end

    [skills_section, commands_section]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n")
    end
  rescue
    _exception ->
      # If Skills Registry isn't available yet, skip this section
      nil
  end

  # Environment information section
  defp build_environment_info(working_dir) do
    git_info = get_git_info(working_dir)
    date = format_date()
    os_info = get_os_info()
    shell_info = get_shell_info()

    """
    # Environment

    **Working Directory:** #{working_dir}
    #{git_info}
    **Date:** #{date}
    **OS:** #{os_info}
    **Shell:** #{shell_info}
    """
  end

  # Get git branch and status information
  defp get_git_info(working_dir) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: working_dir,
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        branch = String.trim(branch)
        "**Git Branch:** #{branch}"

      _ ->
        "**Git:** Not a git repository"
    end
  rescue
    _exception -> "**Git:** Not available"
  end

  # Format current date
  defp format_date do
    now = DateTime.utc_now()
    Calendar.strftime(now, "%Y-%m-%d")
  end

  # Get OS information
  defp get_os_info do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {:unix, subtype} -> "Unix (#{subtype})"
      {:win32, _} -> "Windows"
      other -> inspect(other)
    end
  end

  # Get shell information
  defp get_shell_info do
    case System.get_env("SHELL") do
      nil -> "Unknown"
      shell_path -> shell_path
    end
  end

  # Conflict resolution rules section
  defp build_conflict_resolution_rules do
    """
    # Conflict Resolution

    When you encounter ambiguity or conflicts:

    1. **Project files take precedence:** If DEFT.md, CLAUDE.md, or AGENTS.md
       exists in the working directory, follow those instructions first.

    2. **Observations vs current messages:** If observations conflict with the
       current conversation messages, the messages take precedence. Recent
       conversation is more authoritative than extracted observations.

    3. **Observations vs project instructions:** If observations conflict with
       DEFT.md/CLAUDE.md project instructions, the project instructions take
       precedence. Project files define the ground truth for the codebase.

    4. **Specs are source of truth:** When working on spec-driven projects,
       the specification defines what code must do. If existing code contradicts
       the spec, the code is wrong and should be fixed.

    5. **Ask when uncertain:** If a task is ambiguous or you're unsure of the
       correct approach, ask the user for clarification rather than guessing.

    6. **Preserve existing patterns:** When adding to existing code, follow
       the established patterns, naming conventions, and style.

    7. **Fail safely:** If an operation could be destructive (deleting files,
       force-pushing, etc.), either ask for confirmation first or use the
       safest alternative.
    """
  end
end
