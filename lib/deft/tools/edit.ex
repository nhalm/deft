defmodule Deft.Tools.Edit do
  @moduledoc """
  Tool for editing files via string replacement or line-range replacement.

  Supports two modes:
  1. String match mode - requires unique match of old_string, returns unified diff
  2. Line-range mode - replaces specific line range with new content

  Enforces file scope when set.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "edit"

  @impl Deft.Tool
  def description do
    "Edit a file using string replacement (unique old_string match) or line-range replacement. " <>
      "Returns a unified diff of changes."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "The absolute path to the file to edit"
        },
        "old_string" => %{
          "type" => "string",
          "description" => "String to replace (must match uniquely). Used in string-match mode."
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Replacement string. Used in string-match mode."
        },
        "start_line" => %{
          "type" => "integer",
          "description" => "Starting line number (1-indexed). Used in line-range mode."
        },
        "end_line" => %{
          "type" => "integer",
          "description" => "Ending line number (1-indexed, inclusive). Used in line-range mode."
        },
        "new_content" => %{
          "type" => "string",
          "description" => "New content to replace the line range. Used in line-range mode."
        }
      },
      "required" => ["file_path"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir, file_scope: file_scope}) do
    file_path = args["file_path"]

    # Resolve path relative to working_dir if not absolute
    absolute_path =
      if Path.type(file_path) == :absolute do
        file_path
      else
        Path.join(working_dir, file_path)
      end

    # Check file scope if set
    with :ok <- check_file_scope(absolute_path, file_scope),
         :ok <- validate_file_exists(absolute_path, file_path) do
      # Determine which mode based on provided parameters
      cond do
        args["old_string"] && args["new_string"] ->
          string_match_mode(absolute_path, args["old_string"], args["new_string"], file_path)

        args["start_line"] && args["end_line"] && args["new_content"] ->
          line_range_mode(
            absolute_path,
            args["start_line"],
            args["end_line"],
            args["new_content"],
            file_path
          )

        true ->
          {:error,
           "Must provide either (old_string, new_string) for string-match mode or " <>
             "(start_line, end_line, new_content) for line-range mode"}
      end
    end
  end

  defp check_file_scope(_path, nil), do: :ok

  defp check_file_scope(absolute_path, file_scope) do
    # Normalize both paths for comparison
    normalized_path = Path.expand(absolute_path)

    in_scope? =
      Enum.any?(file_scope, fn scope_path ->
        normalized_scope = Path.expand(scope_path)
        String.starts_with?(normalized_path, normalized_scope)
      end)

    if in_scope? do
      :ok
    else
      {:error, "path outside file scope"}
    end
  end

  defp validate_file_exists(absolute_path, display_path) do
    cond do
      not File.exists?(absolute_path) ->
        {:error, "File not found: #{display_path}"}

      File.dir?(absolute_path) ->
        {:error, "Path is a directory, not a file: #{display_path}"}

      true ->
        :ok
    end
  end

  defp string_match_mode(absolute_path, old_string, new_string, display_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        # Count occurrences
        occurrences = count_occurrences(content, old_string)

        cond do
          occurrences == 0 ->
            # Try to find similar text for helpful error message
            similar_text = find_similar_text(content, old_string)
            error_msg = "String not found in file: #{display_path}"

            error_msg =
              if similar_text do
                error_msg <> "\n\nDid you mean:\n#{similar_text}"
              else
                error_msg
              end

            {:error, error_msg}

          occurrences > 1 ->
            {:error,
             "String appears #{occurrences} times in file (must be unique): #{display_path}"}

          true ->
            # Unique match - perform replacement
            new_content = String.replace(content, old_string, new_string, global: false)

            case File.write(absolute_path, new_content) do
              :ok ->
                diff = generate_unified_diff(content, new_content, display_path)
                {:ok, [%Text{text: diff}]}

              {:error, reason} ->
                {:error, "Failed to write file: #{:file.format_error(reason)}"}
            end
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{:file.format_error(reason)}"}
    end
  end

  defp line_range_mode(absolute_path, start_line, end_line, new_content, display_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total_lines = length(lines)

        with :ok <- validate_line_range(start_line, end_line, total_lines, display_path) do
          perform_line_range_replacement(
            absolute_path,
            content,
            lines,
            start_line,
            end_line,
            new_content,
            display_path
          )
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{:file.format_error(reason)}"}
    end
  end

  defp validate_line_range(start_line, end_line, total_lines, display_path) do
    cond do
      start_line < 1 or end_line < 1 ->
        {:error, "Line numbers must be >= 1"}

      start_line > end_line ->
        {:error, "start_line (#{start_line}) must be <= end_line (#{end_line})"}

      end_line > total_lines ->
        {:error,
         "end_line (#{end_line}) exceeds file length (#{total_lines} lines): #{display_path}"}

      true ->
        :ok
    end
  end

  defp perform_line_range_replacement(
         absolute_path,
         original_content,
         lines,
         start_line,
         end_line,
         new_content,
         display_path
       ) do
    before = Enum.take(lines, start_line - 1)
    after_lines = Enum.drop(lines, end_line)
    new_lines = String.split(new_content, "\n")

    new_file_lines = before ++ new_lines ++ after_lines
    new_file_content = Enum.join(new_file_lines, "\n")

    case File.write(absolute_path, new_file_content) do
      :ok ->
        diff = generate_unified_diff(original_content, new_file_content, display_path)
        {:ok, [%Text{text: diff}]}

      {:error, reason} ->
        {:error, "Failed to write file: #{:file.format_error(reason)}"}
    end
  end

  defp count_occurrences(content, search_string) do
    content
    |> String.split(search_string)
    |> length()
    |> Kernel.-(1)
  end

  defp find_similar_text(content, search_string) do
    # Find text that's somewhat similar to help the user
    # Look for lines that contain some words from the search string
    words = String.split(search_string, ~r/\s+/, trim: true)

    if Enum.empty?(words) do
      nil
    else
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        # Line contains at least one word from search string
        Enum.any?(words, fn word -> String.contains?(line, word) end)
      end)
      |> Enum.take(3)
      |> case do
        [] ->
          nil

        similar_lines ->
          similar_lines
          |> Enum.map(fn {line, line_num} -> "#{line_num}: #{line}" end)
          |> Enum.join("\n")
      end
    end
  end

  defp generate_unified_diff(old_content, new_content, file_path) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    # Simple unified diff generation
    # This is a basic implementation - could be enhanced with proper diff algorithm
    diff_lines = ["--- #{file_path}", "+++ #{file_path}"]

    # Find changed regions
    changes = find_changes(old_lines, new_lines)

    diff_body =
      Enum.map(changes, fn
        {:context, line} -> " #{line}"
        {:delete, line} -> "-#{line}"
        {:add, line} -> "+#{line}"
      end)

    Enum.join(diff_lines ++ diff_body, "\n")
  end

  defp find_changes(old_lines, new_lines) do
    # Simple diff: mark all old lines as deleted, all new lines as added
    # A proper implementation would use LCS or Myers diff algorithm
    # For now, this provides basic visibility into what changed

    max_len = max(length(old_lines), length(new_lines))

    0..(max_len - 1)
    |> Enum.flat_map(fn i ->
      old_line = Enum.at(old_lines, i)
      new_line = Enum.at(new_lines, i)

      cond do
        old_line == new_line and old_line != nil ->
          [{:context, old_line}]

        old_line != nil and new_line != nil ->
          [{:delete, old_line}, {:add, new_line}]

        old_line != nil ->
          [{:delete, old_line}]

        new_line != nil ->
          [{:add, new_line}]

        true ->
          []
      end
    end)
  end
end
