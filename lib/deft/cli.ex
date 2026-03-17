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
  alias Deft.Session.Entry.SessionStart
  alias Deft.Session.Store
  alias Deft.SlashCommand

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

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp determine_command(positional, flags) do
    cond do
      flags[:help] ->
        :help

      flags[:version] ->
        :version

      flags[:prompt] ->
        {:non_interactive, flags[:prompt]}

      # Piped stdin: detect non-TTY input and read prompt from stdin
      Enum.empty?(positional) and stdin_piped?() ->
        prompt = read_stdin()
        {:non_interactive, prompt}

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

  defp execute_command(:resume_list, flags) do
    case Store.list() do
      {:ok, sessions} when sessions == [] ->
        IO.puts("No sessions found.")
        :ok

      {:ok, sessions} ->
        IO.puts("Recent Sessions:")
        IO.puts("================")
        IO.puts("")

        session_list =
          sessions
          |> Enum.take(10)

        session_list
        |> Enum.with_index(1)
        |> Enum.each(fn {session, idx} ->
          formatted_time = Calendar.strftime(session.last_message_at, "%Y-%m-%d %H:%M")

          IO.puts("#{idx}. #{session.session_id} - #{session.working_dir} (#{formatted_time})")

          IO.puts("   #{session.message_count} messages: #{session.last_user_prompt}")
          IO.puts("")
        end)

        IO.puts("Enter session number to resume (or 'q' to quit): ")

        case IO.gets("") |> String.trim() do
          "q" ->
            :ok

          input ->
            case Integer.parse(input) do
              {idx, ""} when idx >= 1 and idx <= length(session_list) ->
                selected_session = Enum.at(session_list, idx - 1)
                execute_command({:resume_session, selected_session.session_id}, flags)

              _ ->
                IO.puts(
                  :stderr,
                  "Invalid selection. Please enter a number between 1 and #{length(session_list)}."
                )

                exit({:shutdown, 1})
            end
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error listing sessions: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command({:resume_session, session_id}, flags) do
    # Load the session state
    case Store.resume(session_id) do
      {:ok, state} ->
        # Display session summary
        display_session_summary(session_id, state)

        # Check if non-interactive continuation was requested
        case flags[:prompt] do
          nil ->
            # No prompt flag - just show summary and exit
            IO.puts(
              "\nUse 'deft resume #{session_id} -p \"prompt\"' to continue non-interactively."
            )

            :ok

          prompt ->
            # Non-interactive continuation
            continue_session_non_interactive(session_id, state, prompt, flags)
        end

      {:error, :enoent} ->
        IO.puts(:stderr, "Error: Session not found: #{session_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error resuming session: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command(:new_session, flags) do
    working_dir = flags[:working_dir] || File.cwd!()
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    session_id = generate_session_id()
    create_session(session_id, working_dir, config)
    agent_pid = start_agent(session_id, working_dir, config)

    Registry.register(Deft.Registry, {:session, session_id}, [])

    IO.puts("Deft session #{session_id} started.")
    IO.puts("Type /quit to exit.\n")

    interactive_loop(agent_pid)
  end

  defp execute_command({:non_interactive, prompt}, flags) do
    # Get working directory and load configuration
    working_dir = flags[:working_dir] || File.cwd!()
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    # Verify API key and register provider
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Create session and start agent
    session_id = generate_session_id()
    create_session(session_id, working_dir, config)
    agent_pid = start_agent(session_id, working_dir, config)

    # Subscribe to agent events
    Registry.register(Deft.Registry, {:session, session_id}, [])

    # Open output handle and run
    output_handle = open_output_handle(flags[:output])
    Deft.Agent.prompt(agent_pid, prompt)
    result = non_interactive_loop(output_handle)

    # Clean up
    close_output_handle(output_handle)
    result
  end

  defp execute_command({:error, message}, _flags) do
    IO.puts(:stderr, "Error: #{message}")
    IO.puts(:stderr, "\nRun 'deft --help' for usage information.")
    exit({:shutdown, 1})
  end

  # Display a summary of the session's last 10 messages
  defp display_session_summary(session_id, state) do
    IO.puts("Session: #{session_id}")
    IO.puts("Working Directory: #{state.working_dir}")
    IO.puts("Model: #{state.model}")
    IO.puts("Messages: #{length(state.messages)}")
    IO.puts("")
    IO.puts("Last 10 messages:")
    IO.puts("=================")
    IO.puts("")

    state.messages
    |> Enum.take(-10)
    |> Enum.each(&display_message_summary/1)
  end

  # Display a single message summary in the format "Role (HH:MM): first 100 chars of content"
  defp display_message_summary(%Deft.Message{} = msg) do
    # Format timestamp as HH:MM
    time = Calendar.strftime(msg.timestamp, "%H:%M")

    # Extract text content and truncate to 100 chars
    content_preview =
      msg.content
      |> Enum.find_value(fn
        %Deft.Message.Text{text: text} -> text
        _ -> nil
      end)
      |> case do
        nil -> "[no text content]"
        text -> String.slice(text, 0..99)
      end

    # Capitalize role
    role = msg.role |> to_string() |> String.capitalize()

    IO.puts("#{role} (#{time}): #{content_preview}")
  end

  # Continue a session non-interactively with a new prompt
  defp continue_session_non_interactive(session_id, state, prompt, flags) do
    IO.puts("\nContinuing session with new prompt...")
    IO.puts("")

    # Build configuration from session state and CLI flags
    working_dir = state.working_dir
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    # Verify API key and register provider
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Start agent with existing messages and cost from the session
    agent_pid = start_agent(session_id, working_dir, config, state.messages, state.session_cost)

    # Subscribe to agent events
    Registry.register(Deft.Registry, {:session, session_id}, [])

    # Open output handle and run
    output_handle = open_output_handle(flags[:output])
    Deft.Agent.prompt(agent_pid, prompt)
    result = non_interactive_loop(output_handle)

    # Clean up
    close_output_handle(output_handle)
    result
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

  # Generate a unique session ID
  defp generate_session_id do
    # Generate a random 8-byte hex string as session ID
    "sess_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # Verify that ANTHROPIC_API_KEY is set
  defp verify_api_key do
    unless System.get_env("ANTHROPIC_API_KEY") do
      IO.puts(:stderr, "Error: ANTHROPIC_API_KEY environment variable not set")
      exit({:shutdown, 1})
    end
  end

  # Create a new session with initial metadata
  defp create_session(session_id, working_dir, config) do
    config_map = Map.from_struct(config)
    session_start = SessionStart.new(session_id, working_dir, config.model, config_map)
    Store.append(session_id, session_start)
  end

  # Start the Agent process for a session
  defp start_agent(
         session_id,
         working_dir,
         config,
         initial_messages \\ [],
         initial_session_cost \\ 0.0
       ) do
    agent_config = %{
      model: config.model,
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: config.turn_limit,
      tool_timeout: config.tool_timeout,
      bash_timeout: config.bash_timeout,
      max_turns: config.turn_limit
    }

    {:ok, agent_pid} =
      Deft.Agent.start_link(
        session_id: session_id,
        config: agent_config,
        messages: initial_messages,
        session_cost: initial_session_cost
      )

    agent_pid
  end

  # Open output handle for non-interactive mode
  defp open_output_handle(nil), do: :stdio

  defp open_output_handle(file_path) do
    case File.open(file_path, [:write, :utf8]) do
      {:ok, handle} ->
        handle

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to open output file: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Close output handle if it's a file
  defp close_output_handle(:stdio), do: :ok
  defp close_output_handle(handle), do: File.close(handle)

  # Event loop for non-interactive mode
  defp non_interactive_loop(output_handle) do
    receive do
      {:agent_event, {:text_delta, delta}} ->
        write_output(output_handle, delta)
        non_interactive_loop(output_handle)

      {:agent_event, {:state_change, :idle}} ->
        # Agent is idle - we're done
        :ok

      {:agent_event, {:error, message}} ->
        IO.puts(:stderr, "Error: #{message}")
        exit({:shutdown, 1})

      {:agent_event, _other_event} ->
        # Ignore other events (tool calls, thinking, etc.)
        non_interactive_loop(output_handle)
    after
      # Timeout after 5 minutes of inactivity
      300_000 ->
        IO.puts(:stderr, "Error: Timeout waiting for response")
        exit({:shutdown, 1})
    end
  end

  # REPL loop for interactive mode
  defp interactive_loop(agent_pid) do
    case IO.gets("deft> ") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      input ->
        prompt = String.trim(input)

        cond do
          prompt == "/quit" ->
            :ok

          prompt == "" ->
            interactive_loop(agent_pid)

          true ->
            case handle_user_input(prompt) do
              {:ok, text_to_send} ->
                Deft.Agent.prompt(agent_pid, text_to_send)
                interactive_response_loop()
                IO.puts("")
                interactive_loop(agent_pid)

              {:error, error_msg} ->
                IO.puts(:stderr, error_msg)
                interactive_loop(agent_pid)
            end
        end
    end
  end

  # Handle user input - dispatch slash commands or pass through regular text
  defp handle_user_input(input) do
    case SlashCommand.parse(input) do
      {:not_slash, text} ->
        {:ok, text}

      {:command, name, args} ->
        case SlashCommand.dispatch(name) do
          {:ok, :command, definition} ->
            # Commands: inject markdown content as user message
            # If args provided, append them to the definition
            text = if args == "", do: definition, else: "#{definition}\n\n#{args}"
            {:ok, text}

          {:ok, :skill, definition} ->
            # Skills: inject definition as instruction
            # TODO: When TUI is implemented, skills should be injected as system-level
            # instructions rather than user messages. For now, CLI treats them like commands.
            # If args provided, append them to the definition
            text =
              if args == "", do: definition, else: "#{definition}\n\nAdditional context: #{args}"

            {:ok, text}

          {:error, :not_found, cmd_name} ->
            {:error, "Unknown command: /#{cmd_name}"}

          {:error, :no_definition, cmd_name} ->
            {:error,
             "Skill '/#{cmd_name}' exists but has no definition (manifest-only, missing --- separator)"}
        end
    end
  end

  # Wait for agent response in interactive mode
  defp interactive_response_loop do
    receive do
      {:agent_event, {:text_delta, delta}} ->
        IO.write(delta)
        interactive_response_loop()

      {:agent_event, {:state_change, :idle}} ->
        IO.puts("")

      {:agent_event, {:error, message}} ->
        IO.puts(:stderr, "\nError: #{message}")

      {:agent_event, _other_event} ->
        interactive_response_loop()
    after
      300_000 ->
        IO.puts(:stderr, "\nError: Timeout waiting for response")
    end
  end

  # Write output to stdout or file
  defp write_output(:stdio, text) do
    IO.write(text)
  end

  defp write_output(file_handle, text) do
    IO.write(file_handle, text)
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

  # Detect if stdin is piped (not a TTY)
  defp stdin_piped? do
    !IO.ANSI.enabled?() or :io.columns() == {:error, :enoent}
  end

  # Read prompt from stdin
  defp read_stdin do
    IO.read(:stdio, :all)
    |> String.trim()
  end
end
