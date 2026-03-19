defmodule Deft.Job.Lead.Supervisor do
  @moduledoc """
  Per-Lead supervisor that manages a Lead gen_statem and its RunnerSupervisor.

  This one_for_one supervisor ensures that both the Lead process and its
  RunnerSupervisor are properly supervised as siblings, preventing orphaned
  RunnerSupervisor processes.

  Process tree per Lead:
  ```
  Deft.Job.Lead.Supervisor (one_for_one)
  ├── Deft.Job.Lead (gen_statem)
  └── Deft.Job.RunnerSupervisor (Task.Supervisor)
  ```

  See orchestration spec section 1 for details.
  """

  use Supervisor

  @doc """
  Starts a Lead.Supervisor with both the Lead gen_statem and RunnerSupervisor.

  ## Options

  - `:lead_id` — Required. Lead identifier.
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

    # RunnerSupervisor name for this Lead
    runner_supervisor_name =
      {:via, Registry, {Deft.ProcessRegistry, {:runner_supervisor, lead_id}}}

    children = [
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
           [Keyword.put(opts, :runner_supervisor, runner_supervisor_name)]},
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
      case Supervisor.which_children(supervisor_pid) do
        children when is_list(children) ->
          Enum.find_value(children, fn
            {:lead, pid, :worker, _} when is_pid(pid) -> pid
            _ -> nil
          end)

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp via_tuple(lead_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:lead_supervisor_wrapper, lead_id}}}
  end
end
