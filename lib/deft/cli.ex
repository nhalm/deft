defmodule Deft.CLI do
  @moduledoc """
  Command-line interface for Deft.

  Handles argument parsing, configuration loading, and dispatching to
  interactive or non-interactive modes.

  ## Commands

  - `deft` - Start a new session in the current directory
  - `deft resume` - List recent sessions and pick one to resume
  - `deft resume <session-id>` - Resume a specific session
  - `deft config` - Show current configuration

  ## Flags

  - `--model <name>` - Override model
  - `--provider <name>` - Override provider
  - `--no-om` - Disable observational memory
  - `--working-dir <path>` - Override working directory
  - `-p <prompt>` - Non-interactive single-turn mode
  - `--output <file>` - Write response to file (non-interactive)
  - `--auto-approve` - Skip plan approval for orchestrated jobs
  - `--help` / `-h` - Show help
  - `--version` - Show version
  """

  alias Deft.Config
  alias Deft.Session.Store

  @version Mix.Project.config()[:version]

  @doc """
  Main entry point for the CLI.

  Parses arguments, loads configuration, and starts the appropriate mode.
  """
  @spec main([String.t()]) :: :ok
  def main(args) do
    # Ensure the OTP application is started
    {:ok, _} = Application.ensure_all_started(:deft)

    # Check for required external dependencies
    check_external_dependencies()

    # Parse arguments
    case parse_args(args) do
      {:ok, command, flags} ->
        execute_command(command, flags)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        IO.puts(:stderr, "\nRun 'deft --help' for usage information.")
        exit({:shutdown, 1})
    end
  end

  # Parse command-line arguments
  defp parse_args(args) do
    {flags, positional, errors} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          provider: :string,
          no_om: :boolean,
          working_dir: :string,
          prompt: :string,
          output: :string,
          auto_approve: :boolean,
          help: :boolean,
          version: :boolean
        ],
        aliases: [
          h: :help,
          p: :prompt
        ]
      )

    # Check for parsing errors
    unless Enum.empty?(errors) do
      error_msg =
        errors
        |> Enum.map(fn {flag, _} -> "Unknown flag: #{flag}" end)
        |> Enum.join(", ")

      {:error, error_msg}
    else
      # Determine the command
      command = determine_command(positional, flags)
      {:ok, command, flags}
    end
  end

  defp determine_command(positional, flags) do
    cond do
      flags[:help] ->
        :help

      flags[:version] ->
        :version

      flags[:prompt] ->
        {:non_interactive, flags[:prompt]}

      positional == ["config"] ->
        :config

      positional == ["resume"] ->
        :resume_list

      match?(["resume", _], positional) ->
        [_cmd, session_id] = positional
        {:resume_session, session_id}

      Enum.empty?(positional) ->
        :new_session

      true ->
        {:error, "Unknown command: #{Enum.join(positional, " ")}"}
    end
  end

  defp execute_command(:help, _flags) do
    print_help()
    :ok
  end

  defp execute_command(:version, _flags) do
    IO.puts("deft v#{@version}")
    :ok
  end

  defp execute_command(:config, flags) do
    working_dir = flags[:working_dir] || File.cwd!()
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    IO.puts("Deft Configuration")
    IO.puts("==================")
    IO.puts("")
    IO.puts("Model:              #{config.model}")
    IO.puts("Provider:           #{config.provider}")
    IO.puts("Turn Limit:         #{config.turn_limit}")
    IO.puts("Tool Timeout:       #{config.tool_timeout}ms")
    IO.puts("Bash Timeout:       #{config.bash_timeout}ms")
    IO.puts("OM Enabled:         #{config.om_enabled}")
    IO.puts("OM Observer Model:  #{config.om_observer_model}")
    IO.puts("OM Reflector Model: #{config.om_reflector_model}")
    IO.puts("")
    IO.puts("Working Directory:  #{working_dir}")

    :ok
  end

  defp execute_command(:resume_list, _flags) do
    case Store.list() do
      {:ok, sessions} when sessions == [] ->
        IO.puts("No sessions found.")
        :ok

      {:ok, sessions} ->
        IO.puts("Recent Sessions:")
        IO.puts("================")
        IO.puts("")

        sessions
        |> Enum.take(10)
        |> Enum.with_index(1)
        |> Enum.each(fn {session, idx} ->
          formatted_time = Calendar.strftime(session.last_message_at, "%Y-%m-%d %H:%M")

          IO.puts("#{idx}. #{session.session_id} - #{session.working_dir} (#{formatted_time})")

          IO.puts("   #{session.message_count} messages: #{session.last_user_prompt}")
          IO.puts("")
        end)

        IO.puts("Use 'deft resume <session-id>' to resume a specific session.")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Error listing sessions: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command({:resume_session, session_id}, _flags) do
    # TODO: Implement interactive resume
    # For now, just show that we parsed it correctly
    IO.puts("Resume session: #{session_id}")
    IO.puts("(Interactive mode not yet implemented)")

    # Verify the session exists
    case Store.resume(session_id) do
      {:ok, state} ->
        IO.puts("Session found: #{state.working_dir}")
        IO.puts("Messages: #{length(state.messages)}")
        :ok

      {:error, :enoent} ->
        IO.puts(:stderr, "Error: Session not found: #{session_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error resuming session: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command(:new_session, _flags) do
    # TODO: Implement interactive mode
    IO.puts("Starting new session...")
    IO.puts("(Interactive mode not yet implemented)")
    :ok
  end

  defp execute_command({:non_interactive, prompt}, _flags) do
    # TODO: Implement non-interactive mode
    # For now, just show that we parsed it correctly
    IO.puts("Non-interactive mode:")
    IO.puts("Prompt: #{prompt}")
    IO.puts("(Non-interactive mode not yet implemented)")
    :ok
  end

  defp execute_command({:error, message}, _flags) do
    IO.puts(:stderr, "Error: #{message}")
    IO.puts(:stderr, "\nRun 'deft --help' for usage information.")
    exit({:shutdown, 1})
  end

  # Build CLI flags map for Config.load
  defp build_cli_flags(flags) do
    flags
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case key do
        :model -> Map.put(acc, :model, value)
        :provider -> Map.put(acc, :provider, value)
        :no_om -> Map.put(acc, :om_enabled, !value)
        _ -> acc
      end
    end)
  end

  defp print_help do
    IO.puts("""
    deft v#{@version}

    Usage:
      deft [FLAGS]                        Start a new session
      deft resume                         List recent sessions
      deft resume <session-id>            Resume a specific session
      deft config                         Show current configuration
      deft -p "prompt" [FLAGS]            Non-interactive mode
      deft --help                         Show this help
      deft --version                      Show version

    Flags:
      --model <name>            Override model
      --provider <name>         Override provider
      --no-om                   Disable observational memory
      --working-dir <path>      Override working directory
      -p <prompt>               Non-interactive single-turn mode
      --output <file>           Write response to file (non-interactive)
      --auto-approve            Skip plan approval for orchestrated jobs
      -h, --help                Show this help
      --version                 Show version

    Examples:
      # Start a new interactive session
      deft

      # Use a specific model
      deft --model claude-opus-4

      # Non-interactive mode
      deft -p "explain this code" --working-dir /path/to/project

      # Resume the last session
      deft resume

    Configuration:
      Configuration is loaded in priority order:
      1. CLI flags (highest)
      2. Project config (.deft/config.yaml in working directory)
      3. User config (~/.deft/config.yaml)
      4. Defaults (lowest)

    Environment Variables:
      ANTHROPIC_API_KEY         API key for Anthropic (required)

    For more information, see: https://github.com/yourusername/deft
    """)
  end

  # Check for required external dependencies
  defp check_external_dependencies do
    missing = []

    missing =
      case System.find_executable("rg") do
        nil -> ["rg (ripgrep)" | missing]
        _ -> missing
      end

    missing =
      case System.find_executable("fd") do
        nil -> ["fd (fd-find)" | missing]
        _ -> missing
      end

    unless Enum.empty?(missing) do
      IO.puts(
        :stderr,
        "Warning: The following external dependencies are missing:"
      )

      Enum.each(missing, fn dep ->
        IO.puts(:stderr, "  - #{dep}")
      end)

      IO.puts(:stderr, "\nSome features may not work correctly without these tools.")
      IO.puts(:stderr, "")
    end
  end
end
