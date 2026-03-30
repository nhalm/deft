defmodule Deft.Job.LeadAgent.Tools.SpawnRunner do
  @moduledoc """
  Tool for spawning a Runner task.

  Sends `{:agent_action, :spawn_runner, type, instructions}` to the Lead orchestrator.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "spawn_runner"

  @impl Deft.Tool
  def description do
    "Spawn a Runner to execute a task. Provide the runner type (:implementation, :testing, :review, :research) " <>
      "and detailed instructions. The Runner will have appropriate tools based on its type."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "runner_type" => %{
          "type" => "string",
          "enum" => ["implementation", "testing", "review", "research"],
          "description" => "The type of Runner to spawn (determines tool set)"
        },
        "instructions" => %{
          "type" => "string",
          "description" =>
            "Detailed instructions for the Runner. Include context, specific tasks, and success criteria."
        }
      },
      "required" => ["runner_type", "instructions"]
    }
  end

  @impl Deft.Tool
  def execute(%{"runner_type" => runner_type, "instructions" => instructions}, %Context{
        parent_pid: parent_pid
      })
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    # Convert string to atom for runner type
    type = String.to_existing_atom(runner_type)

    send(parent_pid, {:agent_action, :spawn_runner, type, instructions})

    {:ok,
     [
       %Text{
         text:
           "Runner spawned (type: #{runner_type}). You will receive results when it completes."
       }
     ]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "spawn_runner requires parent_pid (Lead orchestrator)"}
  end
end
