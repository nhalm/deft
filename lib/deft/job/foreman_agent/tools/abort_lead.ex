defmodule Deft.Job.ForemanAgent.Tools.AbortLead do
  @moduledoc """
  Tool for aborting a Lead that is stuck or going in the wrong direction.

  Sends `{:agent_action, :abort_lead, lead_id}` to the Foreman.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "abort_lead"

  @impl Deft.Tool
  def description do
    "Stop a Lead that is stuck, failing, or going in the wrong direction. " <>
      "Use this as a last resort when steering is not working."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "lead_id" => %{
          "type" => "string",
          "description" => "ID of the Lead to abort"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Reason for aborting (optional)"
        }
      },
      "required" => ["lead_id"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid}) when is_pid(parent_pid) do
    lead_id = Map.get(args, "lead_id")
    reason = Map.get(args, "reason", "No reason provided")

    send(parent_pid, {:agent_action, :abort_lead, lead_id})
    {:ok, [%Text{text: "Aborted Lead '#{lead_id}'. Reason: #{reason}"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "abort_lead requires parent_pid (Foreman orchestrator)"}
  end
end
