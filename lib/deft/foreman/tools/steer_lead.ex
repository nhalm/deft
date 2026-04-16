defmodule Deft.Foreman.Tools.SteerLead do
  @moduledoc """
  Tool for sending course corrections to a Lead.

  Sends `{:agent_action, :steer_lead, lead_id, content}` to the Foreman.Coordinator.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "steer_lead"

  @impl Deft.Tool
  def description do
    "Send a course correction or guidance to a Lead. Use this when a Lead needs redirection, " <>
      "additional context, or clarification."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "lead_id" => %{
          "type" => "string",
          "description" => "ID of the Lead to steer"
        },
        "content" => %{
          "type" => "string",
          "description" => "The steering guidance or course correction"
        }
      },
      "required" => ["lead_id", "content"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    lead_id = Map.get(args, "lead_id")
    content = Map.get(args, "content")

    GenServer.cast(parent_pid, {:agent_action, :steer_lead, lead_id, content})
    {:ok, [%Text{text: "Sent steering to Lead '#{lead_id}'"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "steer_lead requires parent_pid (Foreman.Coordinator orchestrator)"}
  end
end
