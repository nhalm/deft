defmodule Deft.Eval.LeadHelpers do
  @moduledoc """
  Helper functions for Lead eval tests.
  """

  alias Jason.DecodeError

  @doc """
  Validates that all tasks have meaningful done states.
  """
  def all_have_done_states?(tasks) do
    Enum.all?(tasks, fn task ->
      done_state = Map.get(task, "done_state", "")
      description = Map.get(task, "description", "")

      # Both description and done_state must be non-empty and meaningful
      String.length(done_state) > 10 and String.length(description) > 5
    end)
  end

  @doc """
  Validates that task dependencies form a valid DAG (no cycles, only forward refs).
  """
  def has_valid_dependencies?(tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.all?(fn {task, index} ->
      depends_on = Map.get(task, "depends_on", [])

      # All dependency indices must be valid (< current index)
      Enum.all?(depends_on, fn dep_idx ->
        is_integer(dep_idx) and dep_idx >= 0 and dep_idx < index
      end)
    end)
  end

  @doc """
  Validates a task list against expected properties.
  """
  def validate_tasks(tasks, expected) do
    task_count = length(tasks)
    min_tasks = Map.get(expected, :min_tasks, 4)
    max_tasks = Map.get(expected, :max_tasks, 8)

    cond do
      task_count < min_tasks ->
        %{passed: false, reason: "Too few tasks: #{task_count} < #{min_tasks}"}

      task_count > max_tasks ->
        %{passed: false, reason: "Too many tasks: #{task_count} > #{max_tasks}"}

      not all_have_done_states?(tasks) ->
        %{passed: false, reason: "Not all tasks have clear done states"}

      not has_valid_dependencies?(tasks) ->
        %{passed: false, reason: "Invalid dependency structure"}

      true ->
        %{passed: true, reason: nil}
    end
  end

  @doc """
  Extracts JSON from LLM response text.
  Handles both raw JSON and JSON in code blocks.
  """
  def extract_json(text) do
    text
    |> extract_json_string()
    |> parse_json()
  end

  defp extract_json_string(text) do
    cond do
      String.contains?(text, "```json") -> extract_from_code_block(text)
      String.contains?(text, "{") -> extract_from_first_brace(text)
      true -> text
    end
  end

  defp extract_from_code_block(text) do
    text
    |> String.split("```json")
    |> Enum.at(1, "")
    |> String.split("```")
    |> Enum.at(0, "")
    |> String.trim()
  end

  defp extract_from_first_brace(text) do
    case :binary.match(text, "{") do
      {start_idx, _} -> String.slice(text, start_idx..-1//1)
      :nomatch -> text
    end
  end

  defp parse_json(json_text) do
    case Jason.decode(json_text) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, DecodeError.message(error)}
    end
  end
end
