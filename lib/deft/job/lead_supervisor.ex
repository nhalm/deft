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

  Returns `{:ok, pid}` or `{:error, reason}`.

  ## Options

  - See `Deft.Job.Lead.start_link/1` for required options.
  """
  def start_lead(job_id, opts) do
    supervisor = via_tuple(job_id)

    child_spec = %{
      id: {:lead, Keyword.fetch!(opts, :lead_id)},
      start: {Deft.Job.Lead, :start_link, [opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  defp via_tuple(job_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:lead_supervisor, job_id}}}
  end
end
