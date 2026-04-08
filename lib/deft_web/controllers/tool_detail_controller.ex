defmodule DeftWeb.ToolDetailController do
  @moduledoc """
  Returns tool call input/output on demand.

  Looks up the tool call in the session's JSONL store and returns the
  input (args) and output (result) as JSON.
  """

  use DeftWeb, :controller

  alias Deft.Session.Store

  def show(conn, %{"session_id" => session_id, "tool_call_id" => tool_call_id}) do
    case load_tool_detail(session_id, tool_call_id) do
      {:ok, detail} ->
        json(conn, detail)

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Tool call not found"})
    end
  end

  defp load_tool_detail(session_id, tool_call_id) do
    case Store.load(session_id) do
      {:ok, entries} ->
        # Find the tool_use args from the assistant message
        input = find_tool_input(entries, tool_call_id)

        # Find the tool result from the ToolResult entry
        output = find_tool_output(entries, tool_call_id)

        if input || output do
          {:ok, %{input: input, output: output}}
        else
          :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp find_tool_input(entries, tool_call_id) do
    entries
    |> Enum.flat_map(&assistant_content_blocks/1)
    |> Enum.find_value(fn block ->
      type = block["type"] || block[:type]
      id = block["id"] || block[:id]

      if type == "tool_use" && id == tool_call_id do
        args = block["args"] || block[:args] || %{}
        Jason.encode!(args, pretty: true)
      end
    end)
  end

  defp assistant_content_blocks(%Deft.Session.Entry.Message{role: :assistant, content: content}),
    do: content

  defp assistant_content_blocks(_), do: []

  defp find_tool_output(entries, tool_call_id) do
    Enum.find_value(entries, fn
      %Deft.Session.Entry.ToolResult{tool_call_id: ^tool_call_id, result: result} ->
        result

      _ ->
        nil
    end)
  end
end
