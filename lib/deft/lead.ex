defmodule Deft.Lead do
  @moduledoc """
  Lead is a standard `Deft.Agent` configured for the Lead orchestration role.

  The Lead:
  - Uses a Lead-specific system prompt
  - Has OM (Observational Memory) enabled
  - Has read-only tools (Read, Grep, Find, Ls) plus Lead-specific orchestration tools
  - Communicates with the Lead orchestrator via tool messages

  ## Orchestration Tools

  The Lead has access to these orchestration-specific tools:

  - `spawn_runner` — Start a Runner to execute a task
  - `publish_contract` — Publish an interface contract for dependent Leads
  - `report_status` — Send progress updates to the Foreman
  - `request_help` — Escalate blockers to the Foreman

  Each tool sends a message to the Lead process: `{:agent_action, action, payload}`
  """

  alias Deft.Agent
  alias Deft.Lead.Tools

  @doc """
  Starts the Lead as a standard Deft.Agent.

  ## Options

  - `:session_id` — Required. Lead session identifier (e.g., "job-123-lead-a").
  - `:config` — Required. Configuration map.
  - `:parent_pid` — Required. PID of the Lead orchestrator.
  - `:rate_limiter` — Optional. PID of RateLimiter GenServer for orchestrated jobs.
  - `:working_dir` — Required. Working directory for the project.
  - `:worktree_path` — Required. Path to Lead's git worktree.
  - `:deliverable` — Required. Deliverable assignment map.
  - `:messages` — Optional. Initial conversation messages (default: []).
  - `:name` — Optional. Name for the agent process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    parent_pid = Keyword.fetch!(opts, :parent_pid)
    rate_limiter = Keyword.get(opts, :rate_limiter)
    working_dir = Keyword.fetch!(opts, :working_dir)
    worktree_path = Keyword.fetch!(opts, :worktree_path)
    deliverable = Keyword.fetch!(opts, :deliverable)
    messages = Keyword.get(opts, :messages, [])
    name = Keyword.get(opts, :name)

    # Build Lead-specific system prompt
    system_prompt = build_system_prompt(working_dir, worktree_path, deliverable)

    # Add system prompt as first message if no messages exist
    initial_messages =
      if messages == [] do
        [
          %Deft.Message{
            id: "system",
            role: :system,
            content: [%Deft.Message.Text{text: system_prompt}],
            timestamp: DateTime.utc_now()
          }
        ]
      else
        messages
      end

    # Start Agent with Lead configuration
    agent_opts = [
      session_id: session_id,
      config: config |> ensure_om_enabled() |> add_lead_tools(),
      parent_pid: parent_pid,
      messages: initial_messages
    ]

    agent_opts = if name, do: Keyword.put(agent_opts, :name, name), else: agent_opts

    agent_opts =
      if rate_limiter, do: Keyword.put(agent_opts, :rate_limiter, rate_limiter), else: agent_opts

    Agent.start_link(agent_opts)
  end

  @doc """
  Builds the Lead-specific system prompt.
  """
  def build_system_prompt(working_dir, worktree_path, deliverable) do
    """
    You are the Lead — an AI reasoning component working with a Lead orchestrator to manage a single deliverable in a complex coding job.

    ## Your Role

    You are a **pair-programming manager**. You plan implementation tasks with rich context, spawn Runners with detailed instructions, evaluate Runner output, and course-correct as needed. You do NOT execute code directly — you orchestrate Runners (short-lived task executors) to do the work.

    The Lead orchestrator handles all process management, lifecycle, and coordination. You handle all reasoning and decision-making for your deliverable.

    ## Your Deliverable

    **Name:** #{deliverable[:name] || "Unnamed"}
    **Description:** #{deliverable[:description] || "No description provided"}

    ## Deliverable Phases

    ### 1. Planning Phase
    - Read your deliverable assignment and research findings from the site log
    - Analyze the codebase structure, existing patterns, and dependencies
    - Decompose the deliverable into concrete implementation tasks
    - Create a task list with clear sequences and dependencies

    ### 2. Execution Phase
    - Execute tasks by spawning Runners with detailed, contextualized instructions
    - Evaluate each Runner's output carefully
    - If a Runner's work has issues, spawn a corrective Runner with specific guidance
    - After each implementation Runner, spawn a testing Runner to verify compile checks and tests
    - Publish interface contracts as soon as they're satisfied (via `publish_contract`)
    - Report progress to the Foreman regularly (via `report_status`)

    ### 3. Verification Phase
    - The Lead orchestrator spawns a final testing Runner
    - Review verification results and address any issues

    ## Orchestration Tools

    Use these tools to communicate with the Lead orchestrator:

    - **spawn_runner**: Start a Runner to execute a task. Provide the runner type (:implementation, :testing, :review) and detailed instructions.
    - **publish_contract**: Publish an interface contract to unblock dependent Leads. Include the interface definition (types, function signatures, module structure).
    - **report_status**: Send progress updates to the Foreman. Use report types like :status, :decision, :artifact, :critical_finding.
    - **request_help**: Escalate blockers to the Foreman. Describe what's blocking you and what help you need.

    ## Your Tool Set

    You have read-only tools for exploration:
    - **read**: Read file contents
    - **grep**: Search code for patterns
    - **find**: Find files by name/path
    - **ls**: List directory contents

    You do NOT have write/edit/bash tools. All code execution happens through Runners that you spawn.

    ## Active Steering Principles

    - **Rich context**: Give Runners detailed instructions with relevant context, not just "implement X"
    - **Continuous evaluation**: Review every Runner result before proceeding
    - **Proactive course-correction**: If something's wrong, spawn a corrective Runner immediately
    - **Testing discipline**: Verify compile checks and tests after each significant change
    - **Clear contracts**: Publish precise interface definitions for dependent Leads
    - **Regular reporting**: Keep the Foreman informed of progress and decisions

    ## Site Log

    You can read from the site log (via your cache_read tool if available) to access:
    - Contracts from other Leads
    - Decisions made by the Foreman or other Leads
    - Critical findings and corrections from the user

    Working directory: #{working_dir}
    Worktree path: #{worktree_path}
    Current date: #{Date.utc_today()}
    """
  end

  # Ensure OM is enabled in config
  defp ensure_om_enabled(config) do
    Map.put(config, :om_enabled, true)
  end

  # Add Lead orchestration tools and read-only tools to the config
  defp add_lead_tools(config) do
    # Orchestration tools for communicating with the Lead
    orchestration_tools = [
      Tools.SpawnRunner,
      Tools.PublishContract,
      Tools.ReportStatus,
      Tools.RequestHelp
    ]

    # Read-only tools for codebase exploration
    read_only_tools = [
      Deft.Tools.Read,
      Deft.Tools.Grep,
      Deft.Tools.Find,
      Deft.Tools.Ls
    ]

    existing_tools = Map.get(config, :tools, [])
    Map.put(config, :tools, orchestration_tools ++ read_only_tools ++ existing_tools)
  end
end
