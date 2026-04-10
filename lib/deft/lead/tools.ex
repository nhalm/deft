defmodule Deft.Lead.Tools do
  @moduledoc """
  Namespace for Lead orchestration tools.

  These tools allow the Lead to communicate with its Lead orchestrator
  by sending `{:agent_action, action, payload}` messages.
  """

  alias __MODULE__.{
    SpawnRunner,
    PublishContract,
    ReportStatus,
    RequestHelp
  }

  @doc """
  Returns the list of all Lead orchestration tools.
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
