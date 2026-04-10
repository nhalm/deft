defmodule Deft.Lead.Tools.RequestHelp do
  @moduledoc """
  Tool for escalating blockers to the Foreman.

  Sends `{:agent_action, :blocker, description}` to the Lead orchestrator,
  which forwards it to the Foreman as `{:lead_message, :blocker, description, metadata}`.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "request_help"

  @impl Deft.Tool
  def description do
    "Escalate a blocker to the Foreman. Use this when you're stuck and need guidance, " <>
      "when you need information from another Lead, or when the plan needs adjustment. " <>
      "Describe what's blocking you and what help you need."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "description" => %{
          "type" => "string",
          "description" => "Description of the blocker and what help is needed to unblock"
        }
      },
      "required" => ["description"]
    }
  end

  @impl Deft.Tool
  def execute(%{"description" => description}, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    send(parent_pid, {:agent_action, :blocker, description})

    {:ok, [%Text{text: "Help request sent to Foreman. Waiting for response."}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "request_help requires parent_pid (Lead orchestrator)"}
  end
end
