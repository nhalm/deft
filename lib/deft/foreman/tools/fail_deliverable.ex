defmodule Deft.Foreman.Tools.FailDeliverable do
  @moduledoc """
  Tool for marking a Lead's deliverable as failed after a crash or unrecoverable blocker.

  This is used when the Foreman decides not to retry a failed Lead.
  The Lead is removed from tracking and marked as failed, allowing the job to
  proceed with other deliverables or complete if all deliverables are accounted for.

  Sends `{:agent_action, :fail_deliverable, lead_id}` to the Foreman.Coordinator.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "fail_deliverable"

  @impl Deft.Tool
  def description do
    "Mark a Lead's deliverable as failed after a crash or unrecoverable blocker. " <>
      "Use this when you've decided NOT to retry a failed Lead. " <>
      "The deliverable will be counted as done (but failed), allowing the job to proceed."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "lead_id" => %{
          "type" => "string",
          "description" => "ID of the Lead whose deliverable should be marked as failed"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Reason for marking as failed (optional)"
        }
      },
      "required" => ["lead_id"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    lead_id = Map.get(args, "lead_id")
    reason = Map.get(args, "reason", "No reason provided")

    GenServer.cast(parent_pid, {:agent_action, :fail_deliverable, lead_id})
    {:ok, [%Text{text: "Marked deliverable for Lead '#{lead_id}' as failed. Reason: #{reason}"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "fail_deliverable requires parent_pid (Foreman.Coordinator orchestrator)"}
  end
end
