defmodule Deft.Job.ForemanAgent.Tools.ReadyToPlan do
  @moduledoc """
  Tool for signaling that the asking phase is complete and the agent is ready to plan.

  Sends `{:agent_action, :ready_to_plan}` to the Foreman.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "ready_to_plan"

  @impl Deft.Tool
  def description do
    "Signal that clarifying questions are complete and you're ready to begin planning. " <>
      "Call this when you have enough information to proceed with research and decomposition."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  @impl Deft.Tool
  def execute(_args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    send(parent_pid, {:agent_action, :ready_to_plan})
    {:ok, [%Text{text: "Signaled ready to plan. Transitioning to planning phase."}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "ready_to_plan requires parent_pid (Foreman orchestrator)"}
  end
end
