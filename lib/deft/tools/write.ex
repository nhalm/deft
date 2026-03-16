defmodule Deft.Tools.Write do
  @moduledoc """
  Tool for creating or overwriting files.

  Supports:
  - Creating parent directories automatically
  - File scope enforcement when set
  - Byte count in confirmation message
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "write"

  @impl Deft.Tool
  def description do
    "Create or overwrite a file with the given content. Creates parent directories if needed."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "The absolute path to the file to write"
        },
        "content" => %{
          "type" => "string",
          "description" => "The content to write to the file"
        }
      },
      "required" => ["file_path", "content"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir, file_scope: file_scope}) do
    file_path = args["file_path"]
    content = args["content"]

    # Resolve path relative to working_dir if not absolute
    absolute_path =
      if Path.type(file_path) == :absolute do
        file_path
      else
        Path.join(working_dir, file_path)
      end

    # Check file scope if set
    case check_file_scope(absolute_path, file_scope) do
      :ok ->
        write_file(absolute_path, content, file_path)

      {:error, reason} ->
        {:error, reason}
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

  defp write_file(absolute_path, content, display_path) do
    # Create parent directories if needed
    parent_dir = Path.dirname(absolute_path)

    case File.mkdir_p(parent_dir) do
      :ok ->
        # Write the file
        case File.write(absolute_path, content) do
          :ok ->
            byte_count = byte_size(content)
            {:ok, [%Text{text: "Wrote #{byte_count} bytes to #{display_path}"}]}

          {:error, reason} ->
            {:error, "Failed to write file: #{:file.format_error(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to create parent directory: #{:file.format_error(reason)}"}
    end
  end
end
