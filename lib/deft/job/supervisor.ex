defmodule Deft.Job.Supervisor do
  @moduledoc """
  Main supervisor for a Deft job.

  Supervision tree (one_for_one strategy with :temporary restart for all children):
  - Deft.Store (site log instance)
  - Deft.Job.RateLimiter
  - Task.Supervisor (RunnerSupervisor for Foreman's research/verification/merge-resolution Runners)
  - Deft.Job.Foreman
  - Deft.Job.LeadSupervisor (DynamicSupervisor for Leads)

  All children use :temporary restart strategy per orchestration spec section 1.
  The Foreman handles crash recovery explicitly for orchestrated processes.
  """

  use Supervisor

  alias Deft.Project

  @doc """
  Starts the Job Supervisor.

  ## Options

  - `:job_id` — Required. Unique job identifier.
  - `:config` — Required. Configuration map for the job.
  - `:prompt` — Required. Initial user prompt/issue.
  - `:working_dir` — Optional. Working directory (defaults to File.cwd!()).
  - `:resumed_plan` — Optional. Plan to resume from.
  """
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    name = via_tuple(job_id)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    config = Keyword.fetch!(opts, :config)
    prompt = Keyword.fetch!(opts, :prompt)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    resumed_plan = Keyword.get(opts, :resumed_plan)

    # Build paths for Store
    jobs_dir = Project.jobs_dir(working_dir)
    sitelog_path = Path.join([jobs_dir, job_id, "sitelog.dets"])

    # Build via_tuple for RateLimiter (can be used as PID)
    rate_limiter_name = {:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, job_id}}}

    # Build via_tuple for Foreman
    foreman_name = {:via, Registry, {Deft.ProcessRegistry, {:foreman, job_id}}}

    # Build via_tuple for Foreman's RunnerSupervisor
    runner_supervisor_name =
      {:via, Registry, {Deft.ProcessRegistry, {:foreman_runner_supervisor, job_id}}}

    children = [
      # Store (site log instance)
      %{
        id: Deft.Store,
        start:
          {Deft.Store, :start_link,
           [
             [
               name: {:sitelog, job_id},
               type: :sitelog,
               dets_path: sitelog_path,
               owner_name: foreman_name
             ]
           ]},
        restart: :temporary
      },

      # RateLimiter
      %{
        id: Deft.Job.RateLimiter,
        start:
          {Deft.Job.RateLimiter, :start_link,
           [[job_id: job_id, foreman_pid: foreman_name, cost_ceiling: config.work_cost_ceiling]]},
        restart: :temporary
      },

      # RunnerSupervisor for Foreman's Runners (research, verification, merge-resolution)
      %{
        id: :foreman_runner_supervisor,
        start: {Task.Supervisor, :start_link, [[name: runner_supervisor_name]]},
        type: :supervisor
      },

      # Foreman
      %{
        id: Deft.Job.Foreman,
        start:
          {Deft.Job.Foreman, :start_link,
           [
             [
               session_id: job_id,
               config: config,
               prompt: prompt,
               rate_limiter_pid: rate_limiter_name,
               runner_supervisor: runner_supervisor_name,
               working_dir: working_dir,
               resumed_plan: resumed_plan,
               name: foreman_name
             ]
           ]},
        restart: :temporary
      },

      # LeadSupervisor
      %{
        id: Deft.Job.LeadSupervisor,
        start: {Deft.Job.LeadSupervisor, :start_link, [[job_id: job_id]]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via_tuple(job_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:job_supervisor, job_id}}}
  end
end
