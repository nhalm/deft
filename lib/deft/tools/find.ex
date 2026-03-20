defmodule Deft.Tools.Find do
  @moduledoc """
  Tool for finding files by name/pattern using fd or native Path.wildcard fallback.

  Supports:
  - Glob patterns
  - Respects .gitignore
  - Caps at 1000 results
  - Falls back to Path.wildcard if fd not installed
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @max_results 1000

  @impl Deft.Tool
  def name, do: "find"

  @impl Deft.Tool
  def description do
    "Find files by name or pattern. Supports glob patterns. Respects .gitignore. " <>
      "Caps at 1000 results."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern to match files (e.g., '*.ex', '**/test_*.exs')"
        },
        "path" => %{
          "type" => "string",
          "description" => "Directory to search in. Defaults to working directory."
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir}) do
    pattern = args["pattern"]
    path = args["path"]

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
      # Try fd first, fallback to native if not available
      if fd_available?() do
        execute_fd(pattern, search_path)
      else
        execute_native(pattern, search_path)
      end
    end
  end

  # Check if fd is available
  defp fd_available? do
    System.find_executable("fd") != nil
  end

  # Execute using fd
  defp execute_fd(pattern, search_path) do
    args = [
      "--type",
      "f",
      "--max-results",
      "#{@max_results}",
      "--color",
      "never",
      "--glob",
      pattern,
      search_path
    ]

    case System.cmd("fd", args, stderr_to_stdout: true) do
      {output, 0} ->
        # Success (fd v8+ uses exit code 0 for success including zero results)
        files = String.split(output, "\n", trim: true)

        if Enum.empty?(files) do
          {:ok, [%Text{text: "No files found matching pattern: #{pattern}"}]}
        else
          {:ok, [%Text{text: format_output(files, pattern)}]}
        end

      {output, _exit_code} ->
        # Error occurred (fd v8+ uses exit code 1 for errors: bad patterns, invalid paths, etc.)
        {:error, "fd error: #{String.trim(output)}"}
    end
  end

  # Execute using native Path.wildcard
  defp execute_native(pattern, search_path) do
    # Build full pattern path
    full_pattern = Path.join(search_path, pattern)

    # Get matching files
    files =
      full_pattern
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&ignored?/1)
      |> Enum.take(@max_results)

    if Enum.empty?(files) do
      {:ok, [%Text{text: "No files found matching pattern: #{pattern}"}]}
    else
      {:ok, [%Text{text: format_output(files, pattern)}]}
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

  # Format output
  defp format_output(files, pattern) do
    file_count = length(files)

    # Sort files for consistent output
    sorted_files = Enum.sort(files)

    formatted = Enum.join(sorted_files, "\n")

    if file_count >= @max_results do
      "Found #{file_count}+ files matching pattern: #{pattern}\n\n#{formatted}\n\n(Results capped at #{@max_results} files)"
    else
      "Found #{file_count} files matching pattern: #{pattern}\n\n#{formatted}"
    end
  end

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

    # Parse the find output to count files and show top-level structure
    lines = String.split(text, "\n", trim: true)

    # Extract file count from first line if present
    file_count =
      case List.first(lines) do
        line when is_binary(line) ->
          case Regex.run(~r/Found (\d+)\+? files/, line) do
            [_, count] -> String.to_integer(count)
            _ -> length(lines) - 1
          end

        _ ->
          length(lines)
      end

    # Get top-level structure - group by directory
    file_lines = Enum.drop(lines, 1) |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "(")))

    # Group files by top-level directory
    grouped =
      file_lines
      |> Enum.group_by(fn file ->
        parts = Path.split(file)

        case parts do
          [_single] -> "."
          [first | _] -> first
          _ -> "."
        end
      end)

    # Show directory summary
    structure =
      grouped
      |> Enum.map(fn {dir, files} ->
        "  #{dir}/    (#{length(files)} files)"
      end)
      |> Enum.take(10)
      |> Enum.join("\n")

    """
    Found #{file_count} files. Top-level structure:

    #{structure}

    Full results: cache://#{cache_key}
    """
  end
end
