defmodule Deft.Tools.CacheRead do
  @moduledoc """
  Tool for reading cached tool results.

  Retrieves full cached results or filtered subsets. Only included in the tool
  list when the session has active cache entries.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context
  alias Deft.Store

  @impl Deft.Tool
  def name, do: "cache_read"

  @impl Deft.Tool
  def description do
    "Read cached tool results by key. Supports optional line range filtering (lines: \"740-760\") " <>
      "and grep-style pattern filtering (filter: \"pattern\"). Returns the full cached result or filtered subset."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "key" => %{
          "type" => "string",
          "description" => "The cache key from a cache:// reference"
        },
        "lines" => %{
          "type" => "string",
          "description" =>
            "Optional line range for file reads, e.g., \"740-760\" or \"100-200\". Format: \"START-END\" where both are 1-indexed inclusive."
        },
        "filter" => %{
          "type" => "string",
          "description" =>
            "Optional grep-style pattern to filter cached results. Uses regex matching."
        }
      },
      "required" => ["key"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{cache_tid: cache_tid}) do
    key = args["key"]
    lines_param = args["lines"]
    filter_param = args["filter"]

    cond do
      is_nil(cache_tid) ->
        {:error, "Cache not available (session ended or cache not initialized)"}

      is_nil(key) ->
        {:error, "Missing required parameter: key"}

      true ->
        read_from_cache(cache_tid, key, lines_param, filter_param)
    end
  end

  defp read_from_cache(cache_tid, key, lines_param, filter_param) do
    case Store.read(cache_tid, key) do
      {:ok, entry} ->
        result = entry.value
        process_result(result, lines_param, filter_param)

      :miss ->
        {:error, "Cache key not found: #{key}"}
    end
  rescue
    # Handle case where cache has been cleaned up (table owner crashed)
    ArgumentError ->
      {:error, "Cache expired (session or lead ended)"}
  end

  defp process_result(result, nil, nil) do
    # No filtering, return full result
    {:ok, [%Text{text: to_result_string(result)}]}
  end

  defp process_result(result, lines_param, nil) when is_binary(lines_param) do
    # Line range filtering only
    apply_line_filter(result, lines_param)
  end

  defp process_result(result, nil, filter_param) when is_binary(filter_param) do
    # Pattern filtering only
    apply_pattern_filter(result, filter_param)
  end

  defp process_result(result, lines_param, filter_param)
       when is_binary(lines_param) and is_binary(filter_param) do
    # Both filters - apply line range first, then pattern
    with {:ok, [%Text{text: line_filtered}]} <- apply_line_filter(result, lines_param) do
      apply_pattern_filter(line_filtered, filter_param)
    end
  end

  defp apply_line_filter(result, lines_param) do
    case parse_line_range(lines_param) do
      {:ok, start_line, end_line} ->
        result_str = to_result_string(result)
        lines = String.split(result_str, "\n")

        # Extract requested range (1-indexed, inclusive)
        selected_lines =
          lines
          |> Enum.slice((start_line - 1)..(end_line - 1)//1)
          |> Enum.join("\n")

        {:ok, [%Text{text: selected_lines}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_pattern_filter(result, pattern) do
    result_str = to_result_string(result)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        matching_lines =
          result_str
          |> String.split("\n")
          |> Enum.filter(&Regex.match?(regex, &1))
          |> Enum.join("\n")

        if matching_lines == "" do
          {:ok, [%Text{text: "(no matches for pattern: #{pattern})"}]}
        else
          {:ok, [%Text{text: matching_lines}]}
        end

      {:error, _reason} ->
        {:error, "Invalid regex pattern: #{pattern}"}
    end
  end

  defp parse_line_range(lines_param) do
    case String.split(lines_param, "-") do
      [start_str, end_str] ->
        with {start_line, ""} <- Integer.parse(start_str),
             {end_line, ""} <- Integer.parse(end_str),
             true <- start_line > 0 and end_line > 0 and start_line <= end_line do
          {:ok, start_line, end_line}
        else
          _ ->
            {:error,
             "Invalid line range format: #{lines_param}. Expected \"START-END\" (e.g., \"740-760\")"}
        end

      _ ->
        {:error,
         "Invalid line range format: #{lines_param}. Expected \"START-END\" (e.g., \"740-760\")"}
    end
  end

  # Convert cached result to string for processing
  # Use inspect for non-string types to get readable output
  defp to_result_string(result) when is_binary(result), do: result
  defp to_result_string(result), do: inspect(result)
end
