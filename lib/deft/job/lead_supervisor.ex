defmodule Deft.Job.LeadSupervisor do
  @moduledoc """
  DynamicSupervisor for managing Lead processes within a job.

  Each Lead is started on demand by the Foreman and runs under this supervisor.
  Leads use `:temporary` restart strategy since the Foreman handles Lead crash
  recovery explicitly per the orchestration spec.
  """

  use DynamicSupervisor

  @doc """
  Starts the LeadSupervisor.

  ## Options

  - `:job_id` — Required. Job identifier for naming.
  """
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    name = via_tuple(job_id)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a Lead under this supervisor.

  Returns `{:ok, {lead_supervisor_pid, lead_pid}}` or `{:error, reason}`.

  The returned `lead_supervisor_pid` is the Lead.Supervisor PID (the actual
  child process of the DynamicSupervisor), which must be passed to
  `DynamicSupervisor.terminate_child/2` to stop the Lead subtree.

  The returned `lead_pid` is the Lead Coordinator gen_statem PID, which is used for
  monitoring and message passing.

  ## Options

  - See `Deft.Lead.Coordinator.start_link/1` for required options.
  """
  def start_lead(job_id, opts) do
    supervisor = via_tuple(job_id)

    child_spec = %{
      id: {:lead, Keyword.fetch!(opts, :lead_id)},
      start: {Deft.Job.Lead.Supervisor, :start_link, [opts]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, lead_supervisor_pid} ->
        # Return both PIDs: the Lead.Supervisor (for termination) and Lead gen_statem (for monitoring/messages)
        lead_pid = Deft.Job.Lead.Supervisor.lead_pid(Keyword.fetch!(opts, :lead_id))
        {:ok, {lead_supervisor_pid, lead_pid}}

      error ->
        error
    end
  end

  @doc """
  Returns the via tuple for the LeadSupervisor for the given job_id.
  """
  def via_tuple(job_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:lead_supervisor, job_id}}}
  end
end
