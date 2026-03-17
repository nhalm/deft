defmodule Deft.Tools.Read do
  @moduledoc """
  Tool for reading file contents with optional pagination.

  Supports:
  - Line-numbered text output
  - Optional offset/limit for pagination
  - Base64 encoding for image files
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @image_extensions ~w(.png .jpg .jpeg .gif .bmp .webp .svg .ico .tiff .tif)

  @impl Deft.Tool
  def name, do: "read"

  @impl Deft.Tool
  def description do
    "Read file contents with optional offset/limit. Returns content with line numbers. " <>
      "Reads images as base64."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "The absolute path to the file to read"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed). Optional."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read. Optional."
        }
      },
      "required" => ["file_path"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir}) do
    file_path = args["file_path"]
    offset = args["offset"]
    limit = args["limit"]

    # Resolve path relative to working_dir if not absolute
    absolute_path =
      if Path.type(file_path) == :absolute do
        file_path
      else
        Path.join(working_dir, file_path)
      end

    cond do
      not File.exists?(absolute_path) ->
        {:error, "File not found: #{file_path}"}

      File.dir?(absolute_path) ->
        {:error, "Path is a directory, not a file: #{file_path}"}

      is_image?(absolute_path) ->
        read_image(absolute_path)

      true ->
        read_text_file(absolute_path, offset, limit)
    end
  end

  defp is_image?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @image_extensions
  end

  defp read_image(path) do
    case File.read(path) do
      {:ok, binary} ->
        base64 = Base.encode64(binary)
        media_type = media_type_for_ext(Path.extname(path))
        text = "Image: #{Path.basename(path)}\nMedia Type: #{media_type}\nBase64: #{base64}"
        {:ok, [%Text{text: text}]}

      {:error, reason} ->
        {:error, "Failed to read image: #{:file.format_error(reason)}"}
    end
  end

  @media_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".bmp" => "image/bmp",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon",
    ".tiff" => "image/tiff",
    ".tif" => "image/tiff"
  }

  defp media_type_for_ext(ext) do
    Map.get(@media_types, String.downcase(ext), "application/octet-stream")
  end

  defp read_text_file(path, offset, limit) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total_lines = length(lines)

        # Apply offset (1-indexed)
        start_idx = if offset && offset > 0, do: offset - 1, else: 0
        lines_from_offset = Enum.drop(lines, start_idx)

        # Apply limit
        selected_lines =
          if limit && limit > 0 do
            Enum.take(lines_from_offset, limit)
          else
            lines_from_offset
          end

        # Add line numbers (continuing from actual line numbers in file)
        numbered_lines =
          selected_lines
          |> Enum.with_index(start_idx + 1)
          |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
          |> Enum.join("\n")

        result_text =
          if numbered_lines == "" do
            "(empty file or no lines in requested range)"
          else
            "#{numbered_lines}\n\n(#{length(selected_lines)} of #{total_lines} lines)"
          end

        {:ok, [%Text{text: result_text}]}

      {:error, reason} ->
        {:error, "Failed to read file: #{:file.format_error(reason)}"}
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

    # Parse the read output to get line count and first N lines
    lines = String.split(text, "\n")

    # Extract file info from last line if present (format: "(X of Y lines)")
    {line_count, _file_name} =
      case List.last(lines) do
        line when is_binary(line) ->
          # Try to parse the line count info
          case Regex.run(~r/\((\d+) of (\d+) lines\)/, line) do
            [_, _shown, total] ->
              {String.to_integer(total), nil}

            _ ->
              {length(lines), nil}
          end

        _ ->
          {length(lines), nil}
      end

    # Get first 100 lines (excluding line numbers for counting)
    first_lines =
      lines
      |> Enum.take(100)
      |> Enum.join("\n")

    """
    File with #{line_count} lines. First 100 lines shown:

    #{first_lines}

    Full results: cache://#{cache_key}
    """
  end
end
