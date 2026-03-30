defmodule Deft.Job.Lead.Supervisor do
  @moduledoc """
  Per-Lead supervisor that manages a Lead gen_statem, its LeadAgent, and RunnerSupervisor.

  This one_for_one supervisor ensures that the Lead orchestrator, its LeadAgent,
  and both supervisors are properly supervised as siblings.

  Process tree per Lead:
  ```
  Deft.Job.Lead.Supervisor (one_for_one)
  ├── Deft.Agent.ToolRunner (for LeadAgent's tool execution)
  ├── Deft.Job.LeadAgent (standard Deft.Agent)
  ├── Deft.Job.RunnerSupervisor (Task.Supervisor)
  └── Deft.Job.Lead (gen_statem)
  ```

  See orchestration spec section 1 for details.
  """

  use Supervisor

  @doc """
  Starts a Lead.Supervisor with the Lead gen_statem, LeadAgent, and RunnerSupervisor.

  ## Options

  - `:lead_id` — Required. Lead identifier.
  - `:session_id` — Required. Job identifier (used for session naming).
  - `:config` — Required. Configuration map.
  - All other options are passed to the Lead gen_statem.
  """
  def start_link(opts) do
    lead_id = Keyword.fetch!(opts, :lead_id)
    name = via_tuple(lead_id)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    lead_id = Keyword.fetch!(opts, :lead_id)
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    rate_limiter_pid = Keyword.fetch!(opts, :rate_limiter_pid)
    working_dir = Keyword.fetch!(opts, :working_dir)
    worktree_path = Keyword.fetch!(opts, :worktree_path)
    deliverable = Keyword.fetch!(opts, :deliverable)

    # LeadAgent session_id (session_id is the job_id)
    lead_agent_session_id = "#{session_id}-lead-#{lead_id}"

    # LeadAgent ToolRunner name (must use {:tool_runner, session_id} format)
    lead_agent_tool_runner_name =
      {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, lead_agent_session_id}}}

    # LeadAgent name
    lead_agent_name = {:via, Registry, {Deft.ProcessRegistry, {:lead_agent, lead_id}}}

    # Lead name
    lead_name = {:via, Registry, {Deft.ProcessRegistry, {:lead, lead_id}}}

    # RunnerSupervisor name for this Lead
    runner_supervisor_name =
      {:via, Registry, {Deft.ProcessRegistry, {:runner_supervisor, lead_id}}}

    children = [
      # ToolRunner for LeadAgent's tool execution
      %{
        id: :lead_agent_tool_runner,
        start: {Deft.Agent.ToolRunner, :start_link, [[name: lead_agent_tool_runner_name]]},
        type: :supervisor
      },
      # LeadAgent (standard Deft.Agent)
      %{
        id: :lead_agent,
        start:
          {Deft.Job.LeadAgent, :start_link,
           [
             [
               session_id: lead_agent_session_id,
               config: config,
               parent_pid: lead_name,
               rate_limiter: rate_limiter_pid,
               working_dir: working_dir,
               worktree_path: worktree_path,
               deliverable: deliverable,
               messages: [],
               name: lead_agent_name
             ]
           ]},
        restart: :temporary
      },
      # RunnerSupervisor (Task.Supervisor) for spawning Runners
      %{
        id: :runner_supervisor,
        start: {Task.Supervisor, :start_link, [[name: runner_supervisor_name]]},
        type: :supervisor
      },
      # Lead gen_statem
      %{
        id: :lead,
        start:
          {Deft.Job.Lead, :start_link,
           [
             opts
             |> Keyword.put(:runner_supervisor, runner_supervisor_name)
             |> Keyword.put(:lead_agent_pid, lead_agent_name)
             |> Keyword.put(:name, lead_name)
           ]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the PID of the Lead gen_statem child.

  Looks up the Lead child process by its :lead ID under this supervisor.
  Returns `nil` if the Lead process is not running.
  """
  def lead_pid(lead_id) do
    supervisor_pid = GenServer.whereis(via_tuple(lead_id))

    if supervisor_pid do
      # Find the Lead child (id: :lead) in the supervisor's children
      children = Supervisor.which_children(supervisor_pid)

      Enum.find_value(children, fn
        {:lead, pid, :worker, _} when is_pid(pid) -> pid
        _ -> nil
      end)
    else
      nil
    end
  end

  defp via_tuple(lead_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:lead_supervisor_wrapper, lead_id}}}
  end
end
