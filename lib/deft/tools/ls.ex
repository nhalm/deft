defmodule Deft.Tools.Ls do
  @moduledoc """
  Tool for listing directory contents with file types and sizes.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "ls"

  @impl Deft.Tool
  def description do
    "List directory contents with file names, types, and sizes."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Directory path to list. Defaults to current working directory."
        }
      }
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir}) do
    dir_path = args["path"] || "."

    # Resolve path relative to working_dir if not absolute
    absolute_path =
      if Path.type(dir_path) == :absolute do
        dir_path
      else
        Path.join(working_dir, dir_path)
      end

    cond do
      not File.exists?(absolute_path) ->
        {:error, "Directory not found: #{dir_path}"}

      not File.dir?(absolute_path) ->
        {:error, "Path is not a directory: #{dir_path}"}

      true ->
        list_directory(absolute_path)
    end
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        # Get info for each entry
        entries_with_info =
          entries
          |> Enum.map(&get_entry_info(path, &1))
          |> Enum.sort_by(&sort_key/1)

        # Format as text
        formatted = format_entries(entries_with_info)
        {:ok, [%Text{text: formatted}]}

      {:error, reason} ->
        {:error, "Failed to list directory: #{:file.format_error(reason)}"}
    end
  end

  defp get_entry_info(dir_path, name) do
    full_path = Path.join(dir_path, name)

    case File.stat(full_path) do
      {:ok, %File.Stat{type: type, size: size}} ->
        %{name: name, type: type, size: size}

      {:error, _} ->
        # If stat fails, mark as unknown
        %{name: name, type: :unknown, size: 0}
    end
  end

  # Sort directories first, then files, alphabetically within each group
  defp sort_key(%{type: type, name: name}) do
    type_order = if type == :directory, do: 0, else: 1
    {type_order, String.downcase(name)}
  end

  defp format_entries(entries) do
    if Enum.empty?(entries) do
      "(empty directory)"
    else
      lines =
        entries
        |> Enum.map(&format_entry/1)
        |> Enum.join("\n")

      count = length(entries)
      "#{lines}\n\n(#{count} #{pluralize("entry", count)})"
    end
  end

  defp format_entry(%{name: name, type: type, size: size}) do
    type_str = format_type(type)
    size_str = format_size(size)
    "#{type_str} #{String.pad_trailing(name, 40)} #{size_str}"
  end

  defp format_type(:directory), do: "d"
  defp format_type(:regular), do: "f"
  defp format_type(:symlink), do: "l"
  defp format_type(_), do: "?"

  defp format_size(size) when size < 1024, do: "#{size}B"

  defp format_size(size) when size < 1024 * 1024 do
    kb = Float.round(size / 1024, 1)
    "#{kb}KB"
  end

  defp format_size(size) when size < 1024 * 1024 * 1024 do
    mb = Float.round(size / (1024 * 1024), 1)
    "#{mb}MB"
  end

  defp format_size(size) do
    gb = Float.round(size / (1024 * 1024 * 1024), 1)
    "#{gb}GB"
  end

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: "#{word}s"

  @impl Deft.Tool
  def summarize(content_blocks, cache_key) do
    # Extract text from content blocks
    text =
      content_blocks
      |> Enum.map(fn
        %{text: t} -> t
        _ -> ""
      end)
      |> Enum.join("\n")

    # Parse the ls output to count entries and show top-level structure
    lines = String.split(text, "\n", trim: true)

    # Extract entry count from last line if present (format: "(X entries)")
    entry_count =
      case List.last(lines) do
        line when is_binary(line) ->
          case Regex.run(~r/\((\d+) (?:entry|entries)\)/, line) do
            [_, count] -> String.to_integer(count)
            _ -> length(lines) - 1
          end

        _ ->
          length(lines)
      end

    # Count directories vs files
    dir_count = Enum.count(lines, &String.starts_with?(&1, "d "))
    file_count = Enum.count(lines, &String.starts_with?(&1, "f "))

    # Get top-level structure (first 20 entries)
    structure =
      lines
      |> Enum.take(20)
      |> Enum.join("\n")

    """
    Directory with #{entry_count} entries (#{dir_count} directories, #{file_count} files). Top-level structure:

    #{structure}

    Full results: cache://#{cache_key}
    """
  end
end
