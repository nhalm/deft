defmodule Deft.Foreman.Tools.RequestResearch do
  @moduledoc """
  Tool for requesting research on specific topics.

  Sends `{:agent_action, :research, topics}` to the Foreman.Coordinator.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "request_research"

  @impl Deft.Tool
  def description do
    "Request research on specific topics. Each topic should describe what to explore " <>
      "(e.g., 'authentication patterns', 'database schema', 'API endpoints'). " <>
      "The Foreman.Coordinator will spawn research Runners to investigate."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "topics" => %{
          "type" => "array",
          "description" => "List of research topics to investigate",
          "items" => %{"type" => "string"}
        }
      },
      "required" => ["topics"]
    }
  end

  @impl Deft.Tool
  def execute(%{"topics" => topics}, %Context{parent_pid: parent_pid})
      when (is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via)) and
             is_list(topics) do
    send(parent_pid, {:agent_action, :research, topics})
    topic_list = Enum.map_join(topics, ", ", &"'#{&1}'")
    {:ok, [%Text{text: "Requested research on: #{topic_list}"}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "request_research requires parent_pid (Foreman.Coordinator orchestrator)"}
  end

  def execute(_args, _context) do
    {:error, "request_research requires a 'topics' parameter (array of strings)"}
  end
end
