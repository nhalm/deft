defmodule Deft.Job.ForemanAgent.Tools do
  @moduledoc """
  Namespace for ForemanAgent orchestration tools.

  These tools allow the ForemanAgent to communicate with the Foreman orchestrator
  by sending `{:agent_action, action, payload}` messages.
  """

  alias __MODULE__.{
    ReadyToPlan,
    RequestResearch,
    SubmitPlan,
    SpawnLead,
    UnblockLead,
    SteerLead,
    AbortLead,
    FailDeliverable
  }

  @doc """
  Returns the list of all ForemanAgent orchestration tools.
  """
  def all do
    [
      ReadyToPlan,
      RequestResearch,
      SubmitPlan,
      SpawnLead,
      UnblockLead,
      SteerLead,
      AbortLead,
      FailDeliverable
    ]
  end
end
