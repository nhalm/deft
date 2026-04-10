defmodule Deft.Foreman.Tools.UnblockLead do
  @moduledoc """
  Tool for unblocking a dependent Lead by providing a contract.

  Sends `{:agent_action, :unblock_lead, lead_id, contract}` to the Foreman.Coordinator.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "unblock_lead"

  @impl Deft.Tool
  def description do
    "Unblock a dependent Lead by providing the interface contract it needs. " <>
      "Use this for partial dependency unblocking when a contract is satisfied."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "lead_id" => %{
          "type" => "string",
          "description" => "ID of the Lead to unblock"
        },
        "contract" => %{
          "type" => "string",
          "description" => "The interface contract details (function signatures, types, etc.)"
        }
      },
      "required" => ["lead_id", "contract"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    lead_id = Map.get(args, "lead_id")
    contract = Map.get(args, "contract")

    send(parent_pid, {:agent_action, :unblock_lead, lead_id, contract})
    {:ok, [%Text{text: "Unblocked Lead '#{lead_id}' with contract"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "unblock_lead requires parent_pid (Foreman.Coordinator orchestrator)"}
  end
end
