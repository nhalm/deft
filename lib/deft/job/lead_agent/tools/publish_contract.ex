defmodule Deft.Job.LeadAgent.Tools.PublishContract do
  @moduledoc """
  Tool for publishing an interface contract.

  Sends `{:agent_action, :publish_contract, content}` to the Lead orchestrator,
  which forwards it to the Foreman for dependent Lead unblocking.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "publish_contract"

  @impl Deft.Tool
  def description do
    "Publish an interface contract to unblock dependent Leads. Include the complete interface " <>
      "definition: module structure, function signatures, types, and any relevant documentation. " <>
      "This allows downstream Leads to begin work before your full implementation is complete."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "contract" => %{
          "type" => "string",
          "description" =>
            "The interface contract content: module structure, function signatures, types, etc."
        }
      },
      "required" => ["contract"]
    }
  end

  @impl Deft.Tool
  def execute(%{"contract" => contract}, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) do
    send(parent_pid, {:agent_action, :publish_contract, contract})

    {:ok, [%Text{text: "Contract published. Dependent Leads will be notified."}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "publish_contract requires parent_pid (Lead orchestrator)"}
  end
end
