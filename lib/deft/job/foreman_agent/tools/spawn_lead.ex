defmodule Deft.Job.ForemanAgent.Tools.SpawnLead do
  @moduledoc """
  Tool for spawning a Lead to work on a deliverable.

  Sends `{:agent_action, :spawn_lead, deliverable}` to the Foreman.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "spawn_lead"

  @impl Deft.Tool
  def description do
    "Start a Lead to work on a specific deliverable. Provide the deliverable ID and any " <>
      "additional context the Lead needs."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "deliverable_id" => %{
          "type" => "string",
          "description" => "ID of the deliverable from the approved plan"
        },
        "context" => %{
          "type" => "string",
          "description" => "Additional context or instructions for the Lead (optional)"
        }
      },
      "required" => ["deliverable_id"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    deliverable_id = Map.get(args, "deliverable_id")
    context = Map.get(args, "context", "")

    deliverable = %{
      id: deliverable_id,
      context: context
    }

    send(parent_pid, {:agent_action, :spawn_lead, deliverable})
    {:ok, [%Text{text: "Spawned Lead for deliverable '#{deliverable_id}'"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "spawn_lead requires parent_pid (Foreman orchestrator)"}
  end
end
