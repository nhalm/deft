defmodule Deft.Tools.Bash do
  @moduledoc """
  Tool for executing shell commands.

  Supports:
  - Command execution via Port
  - Streaming stdout/stderr to TUI via emit
  - Configurable timeout (default 120s)
  - Output truncation to last 100 lines or 30KB
  - Full output saved to temp file
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @default_timeout_ms 120_000
  @max_output_lines 100
  @max_output_bytes 30_000

  @impl Deft.Tool
  def name, do: "bash"

  @impl Deft.Tool
  def description do
    "Execute a shell command. Streams stdout/stderr to the TUI. " <>
      "Returns truncated output (last 100 lines or 30KB) and saves full output to temp file."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The shell command to execute"
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Timeout in milliseconds. Default is 120000 (2 minutes)."
        }
      },
      "required" => ["command"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir, emit: emit}) do
    command = args["command"]
    timeout = args["timeout"] || @default_timeout_ms

    # Emit that we're starting the command
    emit.("$ #{command}\n")

    # Create temp file for full output
    temp_path = create_temp_file()

    try do
      result = run_command(command, working_dir, timeout, emit, temp_path)

      case result do
        {:ok, output, exit_code} ->
          truncated_output = truncate_output(output)
          result_text = format_result(command, truncated_output, exit_code, temp_path)
          {:ok, [%Text{text: result_text}]}

        {:error, :timeout} ->
          {:error, "Command timed out after #{timeout}ms"}

        {:error, reason} ->
          {:error, "Failed to execute command: #{reason}"}
      end
    after
      # Clean up temp file if it's empty or on error
      if File.exists?(temp_path) do
        case File.stat(temp_path) do
          {:ok, %{size: 0}} -> File.rm(temp_path)
          _ -> :ok
        end
      end
    end
  end

  defp create_temp_file do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    random = :rand.uniform(100_000)
    Path.join(System.tmp_dir!(), "deft_bash_#{timestamp}_#{random}.log")
  end

  defp run_command(command, working_dir, timeout, emit, temp_path) do
    # Use sh -c to execute the command, respecting the working directory
    port =
      Port.open(
        {:spawn, "sh -c #{shell_escape(command)}"},
        [:binary, :stderr_to_stdout, :exit_status, cd: working_dir]
      )

    # Open temp file for writing
    {:ok, file} = File.open(temp_path, [:write, :binary])

    try do
      collect_output(port, file, emit, timeout, <<>>, :os.system_time(:millisecond))
    after
      File.close(file)
    end
  end

  defp collect_output(port, file, emit, timeout, acc, start_time) do
    timeout_remaining = calculate_remaining_timeout(start_time, timeout)

    if timeout_remaining <= 0 do
      Port.close(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          # Emit to TUI in real-time
          emit.(data)
          # Write to temp file
          IO.binwrite(file, data)
          # Accumulate in memory
          new_acc = acc <> data
          collect_output(port, file, emit, timeout, new_acc, start_time)

        {^port, {:exit_status, exit_code}} ->
          {:ok, acc, exit_code}
      after
        timeout_remaining ->
          Port.close(port)
          {:error, :timeout}
      end
    end
  end

  defp calculate_remaining_timeout(start_time, timeout) do
    elapsed = :os.system_time(:millisecond) - start_time
    max(0, timeout - elapsed)
  end

  defp shell_escape(command) do
    # Escape single quotes by replacing ' with '\''
    escaped = String.replace(command, "'", "'\\''")
    "'#{escaped}'"
  end

  defp truncate_output(output) do
    # First, truncate by byte size if needed
    output_by_bytes =
      if byte_size(output) > @max_output_bytes do
        # Take last 30KB
        binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)
      else
        output
      end

    # Then, truncate by line count if needed
    # Split into lines, preserving whether there's a trailing newline
    {lines, has_trailing_newline} =
      case String.split(output_by_bytes, "\n") do
        # If last element is empty, we had a trailing newline
        parts when is_list(parts) ->
          case List.last(parts) do
            "" -> {Enum.drop(parts, -1), true}
            _ -> {parts, false}
          end
      end

    actual_line_count = length(lines)

    if actual_line_count > @max_output_lines do
      # Take last 100 lines
      truncated =
        lines
        |> Enum.take(-@max_output_lines)
        |> Enum.join("\n")

      if has_trailing_newline do
        truncated <> "\n"
      else
        truncated
      end
    else
      output_by_bytes
    end
  end

  defp format_result(_command, output, exit_code, temp_path) do
    output_section =
      if String.trim(output) == "" do
        "(no output)"
      else
        output
      end

    exit_section =
      if exit_code == 0 do
        "Exit code: #{exit_code} (success)"
      else
        "Exit code: #{exit_code} (failure)"
      end

    temp_file_section =
      if File.exists?(temp_path) do
        {:ok, %{size: size}} = File.stat(temp_path)

        if size > @max_output_bytes do
          "\n\nFull output saved to: #{temp_path}"
        else
          ""
        end
      else
        ""
      end

    "#{output_section}\n\n#{exit_section}#{temp_file_section}"
  end
end
