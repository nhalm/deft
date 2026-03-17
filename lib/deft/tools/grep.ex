defmodule Deft.Tools.Grep do
  @moduledoc """
  Tool for searching file contents using ripgrep or native Elixir fallback.

  Supports:
  - Regex pattern matching
  - Glob filtering
  - Case-insensitive search
  - Context lines around matches
  - Respects .gitignore
  - Caps at 100 matches
  - Falls back to native :re + File.stream if rg not installed
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @max_matches 100

  @impl Deft.Tool
  def name, do: "grep"

  @impl Deft.Tool
  def description do
    "Search file contents using regex patterns. Supports glob filtering, case-insensitive search, " <>
      "and context lines. Respects .gitignore. Caps at 100 matches."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "The regex pattern to search for"
        },
        "path" => %{
          "type" => "string",
          "description" => "Directory or file to search in. Defaults to working directory."
        },
        "glob" => %{
          "type" => "string",
          "description" => "Glob pattern to filter files (e.g., '*.ex', '**/*.md')"
        },
        "case_insensitive" => %{
          "type" => "boolean",
          "description" => "Perform case-insensitive search. Default is false."
        },
        "context_lines" => %{
          "type" => "integer",
          "description" => "Number of context lines to show around each match"
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir}) do
    pattern = args["pattern"]
    path = args["path"]
    glob = args["glob"]
    case_insensitive = args["case_insensitive"] || false
    context_lines = args["context_lines"]

    # Resolve search path
    search_path =
      if path do
        if Path.type(path) == :absolute, do: path, else: Path.join(working_dir, path)
      else
        working_dir
      end

    # Check if path exists
    unless File.exists?(search_path) do
      {:error, "Path not found: #{path || working_dir}"}
    else
      # Try ripgrep first, fallback to native if not available
      if rg_available?() do
        execute_rg(pattern, search_path, glob, case_insensitive, context_lines)
      else
        execute_native(pattern, search_path, glob, case_insensitive, context_lines)
      end
    end
  end

  # Check if ripgrep is available
  defp rg_available? do
    System.find_executable("rg") != nil
  end

  # Execute using ripgrep
  defp execute_rg(pattern, search_path, glob, case_insensitive, context_lines) do
    args = build_rg_args(pattern, glob, case_insensitive, context_lines)

    case System.cmd("rg", args ++ [search_path], stderr_to_stdout: true) do
      {output, 0} ->
        # Found matches - truncate to global limit
        truncated_output = truncate_to_match_limit(output, @max_matches)
        {:ok, [%Text{text: format_output(truncated_output, pattern)}]}

      {_output, 1} ->
        # No matches found
        {:ok, [%Text{text: "No matches found for pattern: #{pattern}"}]}

      {output, 2} ->
        # Error occurred
        {:error, "ripgrep error: #{String.trim(output)}"}

      {output, _} ->
        # Other error
        {:error, "ripgrep failed: #{String.trim(output)}"}
    end
  end

  # Build ripgrep arguments
  defp build_rg_args(pattern, glob, case_insensitive, context_lines) do
    args = [
      "--color",
      "never",
      "--line-number"
    ]

    args = if case_insensitive, do: args ++ ["--ignore-case"], else: args
    args = if glob, do: args ++ ["--glob", glob], else: args

    args =
      if context_lines do
        args ++ ["--context", "#{context_lines}"]
      else
        args
      end

    args ++ [pattern]
  end

  # Truncate ripgrep output to first N match lines
  # Match lines have format: filename:linenum:content
  # Context lines have format: filename-linenum-content
  # Separators are: --
  defp truncate_to_match_limit(output, max_matches) do
    lines = String.split(output, "\n", trim: true)

    {truncated, _} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, match_count} ->
        # Match lines have the pattern: filepath:linenum:content
        # Context lines have: filepath-linenum-content
        is_match = Regex.match?(~r/^.+:\d+:/, line)

        new_count = if is_match, do: match_count + 1, else: match_count

        if new_count > max_matches do
          {:halt, {acc, match_count}}
        else
          {:cont, {acc ++ [line], new_count}}
        end
      end)

    Enum.join(truncated, "\n")
  end

  # Execute using native Elixir
  defp execute_native(pattern, search_path, glob, case_insensitive, context_lines) do
    # Compile the regex
    regex_opts = if case_insensitive, do: [:caseless], else: []

    case :re.compile(pattern, regex_opts) do
      {:ok, compiled_pattern} ->
        # Get list of files to search
        files = get_files_to_search(search_path, glob)

        # Search through files
        matches = search_files(files, compiled_pattern, context_lines)

        if Enum.empty?(matches) do
          {:ok, [%Text{text: "No matches found for pattern: #{pattern}"}]}
        else
          result = format_native_matches(matches)
          {:ok, [%Text{text: result}]}
        end

      {:error, reason} ->
        {:error, "Invalid regex pattern: #{inspect(reason)}"}
    end
  end

  # Get list of files to search, respecting .gitignore
  defp get_files_to_search(path, glob) do
    cond do
      File.regular?(path) ->
        # Single file
        [path]

      File.dir?(path) ->
        # Directory - use Path.wildcard with glob pattern
        pattern = if glob, do: Path.join(path, glob), else: Path.join(path, "**/*")

        pattern
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&ignored?/1)

      true ->
        []
    end
  end

  # Check if a file should be ignored (basic .gitignore support)
  defp ignored?(path) do
    parts = Path.split(path)

    Enum.any?(parts, fn part ->
      part == ".git" or part == "node_modules" or part == "_build" or
        part == "deps"
    end)
  end

  # Search through files for matches
  defp search_files(files, compiled_pattern, context_lines) do
    files
    |> Enum.reduce_while([], fn file, acc ->
      case search_file(file, compiled_pattern, context_lines) do
        [] ->
          {:cont, acc}

        file_matches ->
          new_acc = acc ++ file_matches

          if length(new_acc) >= @max_matches do
            {:halt, Enum.take(new_acc, @max_matches)}
          else
            {:cont, new_acc}
          end
      end
    end)
  end

  # Search a single file
  defp search_file(file, compiled_pattern, context_lines) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} ->
          case :re.run(line, compiled_pattern) do
            {:match, _} -> true
            :nomatch -> false
          end
        end)
        |> Enum.map(fn {line, line_num} ->
          context = get_context(lines, line_num, context_lines)
          {file, line_num, line, context}
        end)

      {:error, _} ->
        []
    end
  end

  # Get context lines around a match
  defp get_context(_lines, _line_num, nil), do: []

  defp get_context(lines, line_num, num_lines) do
    start_idx = max(0, line_num - num_lines - 1)
    end_idx = min(length(lines), line_num + num_lines)

    lines
    |> Enum.slice(start_idx, end_idx - start_idx)
    |> Enum.with_index(start_idx + 1)
  end

  # Format ripgrep output
  defp format_output(output, pattern) do
    lines = String.split(output, "\n", trim: true)
    # Count only actual match lines (filename:linenum:content), not context lines or separators
    match_count = Enum.count(lines, fn line -> Regex.match?(~r/^.+:\d+:/, line) end)

    if match_count >= @max_matches do
      "Found #{match_count}+ matches for pattern: #{pattern}\n\n#{output}\n\n(Results capped at #{@max_matches} matches)"
    else
      "Found #{match_count} matches for pattern: #{pattern}\n\n#{output}"
    end
  end

  # Format native matches
  defp format_native_matches(matches) do
    formatted =
      matches
      |> Enum.map(&format_match/1)
      |> Enum.join("\n--\n")

    match_count = length(matches)

    if match_count >= @max_matches do
      "Found #{match_count}+ matches\n\n#{formatted}\n\n(Results capped at #{@max_matches} matches)"
    else
      "Found #{match_count} matches\n\n#{formatted}"
    end
  end

  defp format_match({file, line_num, line, context}) do
    if Enum.empty?(context) do
      "#{file}:#{line_num}:#{line}"
    else
      context
      |> Enum.map(fn {ctx_line, ctx_num} ->
        format_context_line(file, ctx_num, ctx_line, line_num)
      end)
      |> Enum.join("\n")
    end
  end

  defp format_context_line(file, ctx_num, ctx_line, match_line_num) do
    if ctx_num == match_line_num do
      "#{file}:#{ctx_num}:#{ctx_line}"
    else
      "#{file}-#{ctx_num}-#{ctx_line}"
    end
  end
end
