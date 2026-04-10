defmodule Deft.Foreman.Tools do
  @moduledoc """
  Namespace for Foreman orchestration tools.

  These tools allow the Foreman to communicate with the Foreman.Coordinator orchestrator
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
  Returns the list of all Foreman orchestration tools.
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
