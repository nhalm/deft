defmodule Deft.Lead.Tools.ReportStatus do
  @moduledoc """
  Tool for reporting status to the Foreman.

  Sends `{:agent_action, :report, report_type, content}` to the Lead orchestrator,
  which forwards it to the Foreman as `{:lead_message, report_type, content, metadata}`.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  # Valid report types (atoms interned here so String.to_existing_atom/1 works)
  @report_types [:status, :decision, :artifact, :critical_finding, :finding, :plan_amendment]

  @impl Deft.Tool
  def name, do: "report_status"

  @impl Deft.Tool
  def description do
    "Report progress or findings to the Foreman. Choose the appropriate report type: " <>
      ":status (progress update), :decision (implementation choice with rationale), " <>
      ":artifact (file created/modified), :critical_finding (important discovery), " <>
      ":finding (research result), :plan_amendment (request for plan change)."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "report_type" => %{
          "type" => "string",
          "enum" => [
            "status",
            "decision",
            "artifact",
            "critical_finding",
            "finding",
            "plan_amendment"
          ],
          "description" => "The type of report"
        },
        "content" => %{
          "type" => "string",
          "description" => "The report content"
        }
      },
      "required" => ["report_type", "content"]
    }
  end

  @impl Deft.Tool
  def execute(%{"report_type" => report_type, "content" => content}, %Context{
        parent_pid: parent_pid
      })
      when is_pid(parent_pid) or (is_tuple(parent_pid) and elem(parent_pid, 0) == :via) do
    # Convert string to atom for report type
    # @report_types ensures all valid atoms are interned at compile time
    type = String.to_existing_atom(report_type)

    # Defensive check (should never fail since JSON schema validates enum)
    unless type in @report_types do
      raise ArgumentError, "Invalid report_type: #{report_type}"
    end

    GenServer.cast(parent_pid, {:agent_action, :report, type, content})

    {:ok, [%Text{text: "Report sent to Foreman (type: #{report_type})."}]}
  end

  def execute(_args, %Context{parent_pid: nil}) do
    {:error, "report_status requires parent_pid (Lead orchestrator)"}
  end
end
