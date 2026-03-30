defmodule Deft.Job.LeadAgent.Tools do
  @moduledoc """
  Namespace for LeadAgent orchestration tools.

  These tools allow the LeadAgent to communicate with its Lead orchestrator
  by sending `{:agent_action, action, payload}` messages.
  """

  alias __MODULE__.{
    SpawnRunner,
    PublishContract,
    ReportStatus,
    RequestHelp
  }

  @doc """
  Returns the list of all LeadAgent orchestration tools.
  """
  def all do
    [
      SpawnRunner,
      PublishContract,
      ReportStatus,
      RequestHelp
    ]
  end
end
