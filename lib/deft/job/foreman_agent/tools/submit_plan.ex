defmodule Deft.Job.ForemanAgent.Tools.SubmitPlan do
  @moduledoc """
  Tool for submitting a work decomposition plan.

  Sends `{:agent_action, :plan, plan_data}` to the Foreman.

  The plan should include:
  - Deliverables (typically 1-3, rarely >5)
  - Dependency DAG
  - Interface contracts for each dependency
  - Cost/duration estimates
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "submit_plan"

  @impl Deft.Tool
  def description do
    "Submit your work decomposition plan. Include deliverables (1-3 coherent chunks), " <>
      "dependency DAG, interface contracts for dependencies, and estimates."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "deliverables" => %{
          "type" => "array",
          "description" => "List of deliverables, each with id, description, and details",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "description" => %{"type" => "string"},
              "files" => %{
                "type" => "array",
                "items" => %{"type" => "string"}
              },
              "estimated_complexity" => %{
                "type" => "string",
                "enum" => ["low", "medium", "high"]
              }
            },
            "required" => ["id", "description"]
          }
        },
        "dependencies" => %{
          "type" => "array",
          "description" => "List of dependencies: which deliverable blocks which",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "from" => %{
                "type" => "string",
                "description" => "Deliverable ID that must complete first"
              },
              "to" => %{"type" => "string", "description" => "Deliverable ID that is blocked"},
              "contract" => %{
                "type" => "string",
                "description" => "What specific interface/contract unblocks this"
              }
            },
            "required" => ["from", "to", "contract"]
          }
        },
        "rationale" => %{
          "type" => "string",
          "description" => "Explanation of the decomposition strategy"
        }
      },
      "required" => ["deliverables", "dependencies", "rationale"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{parent_pid: parent_pid})
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    deliverables = Map.get(args, "deliverables", [])
    dependencies = Map.get(args, "dependencies", [])
    rationale = Map.get(args, "rationale", "")

    plan_data = %{
      deliverables: deliverables,
      dependencies: dependencies,
      rationale: rationale
    }

    send(parent_pid, {:agent_action, :plan, plan_data})

    summary = """
    Submitted plan with #{length(deliverables)} deliverable(s) and #{length(dependencies)} dependency edge(s).

    Rationale: #{rationale}

    Waiting for user approval...
    """

    {:ok, [%Text{text: summary}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "submit_plan requires parent_pid (Foreman orchestrator)"}
  end
end
