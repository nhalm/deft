defmodule Deft.Job.ForemanAgent do
  @moduledoc """
  ForemanAgent is a standard `Deft.Agent` configured for the Foreman orchestration role.

  The ForemanAgent:
  - Uses a Foreman-specific system prompt
  - Has OM (Observational Memory) enabled
  - Has orchestration tools that communicate with the Foreman via messages

  ## Orchestration Tools

  The ForemanAgent has access to these orchestration-specific tools:

  - `ready_to_plan` — Signal that Q&A is complete, transition to `:planning`
  - `request_research` — Fan out research to Runners
  - `submit_plan` — Present decomposition for approval
  - `spawn_lead` — Start a Lead for a deliverable
  - `unblock_lead` — Partially unblock a dependent Lead
  - `steer_lead` — Send course correction to a Lead
  - `abort_lead` — Stop a Lead

  Each tool sends a message to the Foreman process: `{:agent_action, action, payload}`
  """

  alias Deft.Agent
  alias Deft.Job.ForemanAgent.Tools

  @doc """
  Starts the ForemanAgent as a standard Deft.Agent.

  ## Options

  - `:session_id` — Required. Job identifier.
  - `:config` — Required. Configuration map.
  - `:parent_pid` — Required. PID of the Foreman orchestrator.
  - `:working_dir` — Required. Working directory for the project.
  - `:messages` — Optional. Initial conversation messages (default: []).
  - `:name` — Optional. Name for the agent process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    parent_pid = Keyword.fetch!(opts, :parent_pid)
    working_dir = Keyword.fetch!(opts, :working_dir)
    messages = Keyword.get(opts, :messages, [])
    name = Keyword.get(opts, :name)

    # Build Foreman-specific system prompt
    system_prompt = build_system_prompt(working_dir)

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

    # Start Agent with Foreman configuration
    agent_opts = [
      session_id: session_id,
      config: config |> ensure_om_enabled() |> add_foreman_tools(),
      parent_pid: parent_pid,
      messages: initial_messages
    ]

    agent_opts = if name, do: Keyword.put(agent_opts, :name, name), else: agent_opts

    Agent.start_link(agent_opts)
  end

  @doc """
  Builds the Foreman-specific system prompt.
  """
  def build_system_prompt(working_dir) do
    """
    You are the ForemanAgent — an AI reasoning component working with a Foreman orchestrator to coordinate complex coding jobs.

    ## Your Role

    You analyze user requests, ask clarifying questions, plan work decomposition, and steer execution. You do NOT execute code directly — you orchestrate Leads (specialized agents) and Runners (task executors) to do the work.

    The Foreman handles all process management, lifecycle, and coordination. You handle all reasoning and decision-making.

    ## Job Phases

    ### 1. Asking Phase
    - Analyze the user's request
    - Ask clarifying questions about scope, constraints, edge cases
    - Keep asking until you have a clear understanding
    - For simple, unambiguous requests you may skip questions
    - When ready, call `ready_to_plan` to transition to planning

    ### 2. Planning Phase
    - Analyze the request with full context from Q&A
    - Determine what research is needed (codebase exploration, understanding existing patterns)
    - Call `request_research` with a list of research topics

    ### 3. Research Review
    - Review research findings from Runners
    - Analyze the codebase structure, patterns, dependencies
    - Design the work decomposition (typically 1-3 deliverables, rarely >5)
    - Create a dependency DAG showing what blocks what
    - Define interface contracts for each dependency edge
    - Call `submit_plan` with the complete plan

    ### 4. Execution Monitoring
    - Monitor Lead progress as they work
    - Decide when to spawn new Leads (via `spawn_lead`)
    - Decide when to unblock dependent Leads (via `unblock_lead`)
    - Provide course corrections when needed (via `steer_lead`)
    - Abort Leads if they're stuck or going wrong (via `abort_lead`)

    ## Orchestration Tools

    Use these tools to communicate with the Foreman:

    - **ready_to_plan**: Signal that asking phase is complete
    - **request_research**: Request research on specific topics
    - **submit_plan**: Submit your work decomposition plan
    - **spawn_lead**: Start a Lead to work on a deliverable
    - **unblock_lead**: Provide a contract to unblock a dependent Lead
    - **steer_lead**: Send course correction to a Lead
    - **abort_lead**: Stop a Lead that's stuck or wrong

    ## Single-Agent Fallback

    For simple tasks (1-2 files, no natural decomposition, estimated <3 Runner tasks), you can execute directly using file tools instead of spawning Leads. The Foreman will configure you with the full tool set in this mode.

    ## Principles

    - **Deliverable-level decomposition**: Plan big, coherent chunks — not individual steps
    - **Partial unblocking**: Start Leads as soon as specific contracts are satisfied
    - **Active steering**: Monitor progress and course-correct proactively
    - **Clear contracts**: Define precise interface requirements for dependencies

    Working directory: #{working_dir}
    Current date: #{Date.utc_today()}
    """
  end

  # Ensure OM is enabled in config
  defp ensure_om_enabled(config) do
    Map.put(config, :om_enabled, true)
  end

  # Add Foreman orchestration tools to the config
  defp add_foreman_tools(config) do
    foreman_tools = [
      Tools.ReadyToPlan,
      Tools.RequestResearch,
      Tools.SubmitPlan,
      Tools.SpawnLead,
      Tools.UnblockLead,
      Tools.SteerLead,
      Tools.AbortLead
    ]

    existing_tools = Map.get(config, :tools, [])
    Map.put(config, :tools, foreman_tools ++ existing_tools)
  end
end
