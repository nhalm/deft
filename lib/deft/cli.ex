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
  - `--auto-approve-all` - Skip plan approval for orchestrated jobs
  - `--help` / `-h` - Show help
  - `--version` - Show version
  """

  alias Deft.Config
  alias Deft.Git
  alias Deft.Git.Job, as: GitJob
  alias Deft.Issue.ElicitationPrompt
  alias Deft.Issues
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

    # Check for required external dependencies (skip for issue commands)
    unless issue_command?(args) do
      check_external_dependencies()
    end

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

  # Check if the command is an issue command
  defp issue_command?(args) do
    case args do
      ["issue" | _] -> true
      _ -> false
    end
  end

  # Ensure the Issues GenServer is started
  defp ensure_issues_started(flags) do
    case Process.whereis(Issues) do
      nil ->
        # Load config to get compaction_days setting
        working_dir = flags[:working_dir] || File.cwd!()
        cli_flags = build_cli_flags(flags)
        config = Config.load(cli_flags, working_dir)

        case Issues.start_link(compaction_days: config.issues_compaction_days) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
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
          auto_approve_all: :boolean,
          help: :boolean,
          version: :boolean,
          status: :string,
          priority: :integer,
          title: :string,
          blocked_by: :string,
          quick: :boolean
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

      # Issue commands
      match?(["issue", "create" | _], positional) ->
        ["issue", "create" | title_parts] = positional

        if Enum.empty?(title_parts) do
          {:error, "Issue title is required"}
        else
          title = Enum.join(title_parts, " ")
          {:issue_create, title}
        end

      match?(["issue", "show", _], positional) ->
        [_cmd, _subcmd, issue_id] = positional
        {:issue_show, issue_id}

      match?(["issue", "close", _], positional) ->
        [_cmd, _subcmd, issue_id] = positional
        {:issue_close, issue_id}

      match?(["issue", "update", _], positional) ->
        [_cmd, _subcmd, issue_id] = positional
        {:issue_update, issue_id}

      positional == ["issue", "list"] ->
        :issue_list

      positional == ["issue", "ready"] ->
        :issue_ready

      match?(["issue", "dep", "add", _], positional) ->
        [_cmd, _subcmd, _action, issue_id] = positional
        {:issue_dep_add, issue_id}

      match?(["issue", "dep", "remove", _], positional) ->
        [_cmd, _subcmd, _action, issue_id] = positional
        {:issue_dep_remove, issue_id}

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

  defp execute_command({:issue_show, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    case Issues.get(issue_id) do
      {:ok, issue} ->
        display_issue(issue)
        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command({:issue_close, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get all issues to find which ones were blocked by this issue
    all_issues = Issues.list(status: [:open, :in_progress])
    previously_blocked = find_issues_blocked_by(all_issues, issue_id)

    # Close the issue
    case Issues.close(issue_id) do
      {:ok, _issue} ->
        IO.puts("Issue #{issue_id} closed successfully.")

        # Check if any previously blocked issues are now unblocked
        newly_unblocked = find_newly_unblocked(previously_blocked)

        unless Enum.empty?(newly_unblocked) do
          IO.puts("")
          IO.puts("Newly unblocked issues:")

          Enum.each(newly_unblocked, fn issue ->
            IO.puts("  - #{issue.id}: #{issue.title}")
          end)
        end

        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to close issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command(:issue_list, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Build filter options from flags
    opts = build_issue_list_opts(flags)

    # Get filtered issues
    issues = Issues.list(opts)

    # Display in tabular format
    display_issue_list(issues)
    :ok
  end

  defp execute_command(:issue_ready, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get ready issues (sorted by priority, then created_at)
    issues = Issues.ready()

    # Display in tabular format
    display_issue_list(issues)
    :ok
  end

  defp execute_command({:issue_create, title}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Check for --quick flag
    if flags[:quick] do
      # Quick mode: create issue with title only
      create_quick_issue(title, flags)
    else
      # Interactive mode: start elicitation session
      create_interactive_issue(title, flags)
    end
  end

  defp execute_command({:issue_update, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Build attrs map from flags
    attrs = build_issue_update_attrs(flags)

    # Validate that at least one update flag was provided
    if map_size(attrs) == 0 do
      IO.puts(
        :stderr,
        "Error: No update flags provided. Use --title, --priority, --status, or --blocked-by"
      )

      exit({:shutdown, 1})
    end

    # Update the issue
    case Issues.update(issue_id, attrs) do
      {:ok, issue} ->
        IO.puts("Issue #{issue_id} updated successfully.")
        IO.puts("")
        display_issue(issue)
        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})

      {:error, :cycle_detected} ->
        IO.puts(:stderr, "Error: Adding these dependencies would create a cycle")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to update issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command({:issue_dep_add, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get blocker_id from --blocked-by flag
    blocker_id = flags[:blocked_by]

    if is_nil(blocker_id) do
      IO.puts(:stderr, "Error: --blocked-by flag is required")
      exit({:shutdown, 1})
    end

    # Add the dependency
    case Issues.add_dependency(issue_id, blocker_id) do
      {:ok, _issue} ->
        IO.puts("Added dependency: #{issue_id} is now blocked by #{blocker_id}")
        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})

      {:error, :blocker_not_found} ->
        IO.puts(:stderr, "Error: Blocker issue not found: #{blocker_id}")
        exit({:shutdown, 1})

      {:error, :cycle_detected} ->
        IO.puts(:stderr, "Error: Adding this dependency would create a cycle")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to add dependency: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp execute_command({:issue_dep_remove, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get blocker_id from --blocked-by flag
    blocker_id = flags[:blocked_by]

    if is_nil(blocker_id) do
      IO.puts(:stderr, "Error: --blocked-by flag is required")
      exit({:shutdown, 1})
    end

    # Remove the dependency
    case Issues.remove_dependency(issue_id, blocker_id) do
      {:ok, _issue} ->
        IO.puts("Removed dependency: #{issue_id} is no longer blocked by #{blocker_id}")
        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to remove dependency: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
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
    # Clean up orphaned git artifacts from crashed jobs
    working_dir = flags[:working_dir] || File.cwd!()
    cleanup_git_orphans(working_dir, flags[:auto_approve_all])

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

    # Clean up orphaned git artifacts from crashed jobs
    cleanup_git_orphans(working_dir, flags[:auto_approve_all])

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
      deft issue create <title> [FLAGS]   Create a new issue (interactive)
      deft issue list [FLAGS]             List issues
      deft issue show <id>                Show issue details
      deft issue close <id>               Close an issue
      deft issue ready                    List ready issues
      deft issue update <id> [FLAGS]      Update an issue
      deft issue dep add <id> --blocked-by <blocker_id>      Add a dependency
      deft issue dep remove <id> --blocked-by <blocker_id>   Remove a dependency
      deft --help                         Show this help
      deft --version                      Show version

    Flags:
      --model <name>            Override model
      --provider <name>         Override provider
      --no-om                   Disable observational memory
      --working-dir <path>      Override working directory
      -p <prompt>               Non-interactive single-turn mode
      --output <file>           Write response to file (non-interactive)
      --auto-approve-all        Skip plan approval for orchestrated jobs
      --priority <0-4>          Issue priority (for issue commands)
      --quick                   Skip interactive elicitation (issue create only)
      --blocked-by <ids>        Comma-separated issue IDs this depends on
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

      # Create an issue (interactive mode with AI elicitation)
      deft issue create "Add JWT authentication"

      # Create an issue quickly (title only)
      deft issue create "Fix typo in README" --quick

      # Create an issue with priority and dependencies
      deft issue create "Implement user profiles" --priority 1 --blocked-by deft-a1b2

      # Add a dependency to an existing issue
      deft issue dep add deft-b3c4 --blocked-by deft-a1b2

      # Remove a dependency from an existing issue
      deft issue dep remove deft-b3c4 --blocked-by deft-a1b2

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
         _initial_session_cost \\ 0.0
       ) do
    agent_config = %{
      model: config.model,
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: config.turn_limit,
      tool_timeout: config.tool_timeout,
      bash_timeout: config.bash_timeout,
      max_turns: config.turn_limit,
      tools: [Deft.Tools.UseSkill, Deft.Tools.IssueCreate]
    }

    {:ok, _worker_pid} =
      Deft.Session.Supervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: initial_messages,
        project_dir: working_dir
      )

    # Look up the Agent PID from the registry
    [{agent_pid, _}] = Registry.lookup(Deft.Registry, {:agent, session_id})
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

  # Clean up orphaned git artifacts from crashed jobs
  defp cleanup_git_orphans(working_dir, auto_approve) do
    # Only attempt cleanup if we're in a git repository
    case Git.cmd(["rev-parse", "--git-dir"]) do
      {_output, 0} ->
        # We're in a git repo - attempt cleanup
        GitJob.cleanup_orphans(
          working_dir: working_dir,
          auto_approve: auto_approve || false
        )

      {_error, _exit_code} ->
        # Not a git repo - skip cleanup silently
        :ok
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

  # Build options for Issues.list/1 from CLI flags
  defp build_issue_list_opts(flags) do
    opts = []

    # Add status filter if provided
    opts =
      case flags[:status] do
        nil ->
          opts

        status_str ->
          status_atom = String.to_existing_atom(status_str)
          Keyword.put(opts, :status, status_atom)
      end

    # Add priority filter if provided
    opts =
      case flags[:priority] do
        nil -> opts
        priority -> Keyword.put(opts, :priority, priority)
      end

    opts
  rescue
    ArgumentError ->
      IO.puts(:stderr, "Error: Invalid status value. Must be one of: open, in_progress, closed")
      exit({:shutdown, 1})
  end

  # Build attrs map for Issues.update/2 from CLI flags
  defp build_issue_update_attrs(flags) do
    %{}
    |> maybe_add_title(flags[:title])
    |> maybe_add_priority(flags[:priority])
    |> maybe_add_status(flags[:status])
    |> maybe_add_dependencies(flags[:blocked_by])
  end

  # Add title to attrs if provided
  defp maybe_add_title(attrs, nil), do: attrs
  defp maybe_add_title(attrs, title), do: Map.put(attrs, :title, title)

  # Add priority to attrs if provided
  defp maybe_add_priority(attrs, nil), do: attrs

  defp maybe_add_priority(attrs, priority) when priority in 0..4 do
    Map.put(attrs, :priority, priority)
  end

  defp maybe_add_priority(_attrs, priority) do
    IO.puts(:stderr, "Error: Priority must be 0-4, got: #{priority}")
    exit({:shutdown, 1})
  end

  # Add status to attrs if provided
  defp maybe_add_status(attrs, nil), do: attrs

  defp maybe_add_status(attrs, status_str) do
    case parse_status(status_str) do
      {:ok, status_atom} -> Map.put(attrs, :status, status_atom)
      {:error, msg} -> exit_with_error(msg)
    end
  end

  # Parse status string to atom
  defp parse_status(status_str) do
    status_atom = String.to_existing_atom(status_str)

    if status_atom in [:open, :in_progress, :closed] do
      {:ok, status_atom}
    else
      {:error, "Error: Invalid status value. Must be one of: open, in_progress, closed"}
    end
  rescue
    ArgumentError ->
      {:error, "Error: Invalid status value. Must be one of: open, in_progress, closed"}
  end

  # Add dependencies to attrs if provided
  defp maybe_add_dependencies(attrs, nil), do: attrs

  defp maybe_add_dependencies(attrs, blocked_by_str) do
    deps =
      blocked_by_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(attrs, :dependencies, deps)
  end

  # Helper to exit with an error message
  defp exit_with_error(message) do
    IO.puts(:stderr, message)
    exit({:shutdown, 1})
  end

  # Display a list of issues in tabular format
  defp display_issue_list(issues) when issues == [] do
    IO.puts("No issues found.")
  end

  defp display_issue_list(issues) do
    # Calculate column widths
    id_width =
      max(
        2,
        Enum.max_by(issues, &String.length(&1.id), fn -> %{id: "id"} end).id |> String.length()
      )

    priority_width = 8

    status_width =
      max(6, Enum.max_by(issues, &status_length/1, fn -> %{status: :open} end) |> status_length())

    # Title width is flexible - use remaining space, but at least 20 chars
    title_width = 60

    # Print header
    header = [
      String.pad_trailing("ID", id_width),
      String.pad_trailing("Priority", priority_width),
      String.pad_trailing("Status", status_width),
      "Title"
    ]

    IO.puts(Enum.join(header, "  "))
    IO.puts(String.duplicate("-", id_width + priority_width + status_width + title_width + 6))

    # Print each issue
    Enum.each(issues, fn issue ->
      row = [
        String.pad_trailing(issue.id, id_width),
        String.pad_trailing(format_priority_short(issue.priority), priority_width),
        String.pad_trailing(format_status(issue.status), status_width),
        truncate_title(issue.title, title_width)
      ]

      IO.puts(Enum.join(row, "  "))
    end)
  end

  # Helper to get status string length
  defp status_length(issue), do: format_status(issue.status) |> String.length()

  # Format status for display
  defp format_status(:open), do: "open"
  defp format_status(:in_progress), do: "in_progress"
  defp format_status(:closed), do: "closed"

  # Format priority for table display (short version)
  defp format_priority_short(0), do: "0 (crit)"
  defp format_priority_short(1), do: "1 (high)"
  defp format_priority_short(2), do: "2 (med)"
  defp format_priority_short(3), do: "3 (low)"
  defp format_priority_short(4), do: "4 (back)"
  defp format_priority_short(p), do: to_string(p)

  # Truncate title if too long
  defp truncate_title(title, max_width) do
    if String.length(title) <= max_width do
      title
    else
      String.slice(title, 0, max_width - 3) <> "..."
    end
  end

  # Display a single issue with all structured fields
  defp display_issue(issue) do
    IO.puts("Issue: #{issue.id}")
    IO.puts("Title: #{issue.title}")
    IO.puts("Status: #{issue.status}")
    IO.puts("Priority: #{format_priority(issue.priority)}")
    IO.puts("Source: #{issue.source}")
    IO.puts("")

    # Context
    IO.puts("Context:")

    if issue.context == "" do
      IO.puts("  (none)")
    else
      IO.puts("  #{issue.context}")
    end

    IO.puts("")

    # Acceptance Criteria
    IO.puts("Acceptance Criteria:")

    if Enum.empty?(issue.acceptance_criteria) do
      IO.puts("  (none)")
    else
      Enum.each(issue.acceptance_criteria, fn criterion ->
        IO.puts("  - #{criterion}")
      end)
    end

    IO.puts("")

    # Constraints
    IO.puts("Constraints:")

    if Enum.empty?(issue.constraints) do
      IO.puts("  (none)")
    else
      Enum.each(issue.constraints, fn constraint ->
        IO.puts("  - #{constraint}")
      end)
    end

    IO.puts("")

    # Dependencies
    IO.puts("Dependencies:")

    if Enum.empty?(issue.dependencies) do
      IO.puts("  (none)")
    else
      Enum.each(issue.dependencies, fn dep_id ->
        IO.puts("  - #{dep_id}")
      end)
    end

    IO.puts("")

    # Timestamps
    IO.puts("Created: #{format_timestamp(issue.created_at)}")
    IO.puts("Updated: #{format_timestamp(issue.updated_at)}")

    if issue.closed_at do
      IO.puts("Closed: #{format_timestamp(issue.closed_at)}")
    end

    if issue.job_id do
      IO.puts("Job ID: #{issue.job_id}")
    end
  end

  # Format priority for display
  defp format_priority(0), do: "0 (critical)"
  defp format_priority(1), do: "1 (high)"
  defp format_priority(2), do: "2 (medium)"
  defp format_priority(3), do: "3 (low)"
  defp format_priority(4), do: "4 (backlog)"
  defp format_priority(p), do: to_string(p)

  # Format ISO 8601 timestamp for display
  defp format_timestamp(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

      _ ->
        timestamp
    end
  end

  # Find issues that have the given issue ID in their dependencies
  defp find_issues_blocked_by(issues, blocker_id) do
    Enum.filter(issues, fn issue ->
      blocker_id in issue.dependencies
    end)
  end

  # Find which issues from the list are now unblocked (ready)
  defp find_newly_unblocked(issues) do
    # Re-query to get current ready status
    ready_issues = Issues.ready()
    ready_ids = MapSet.new(ready_issues, & &1.id)

    Enum.filter(issues, fn issue ->
      MapSet.member?(ready_ids, issue.id)
    end)
  end

  # Create an issue in quick mode (title only)
  defp create_quick_issue(title, flags) do
    attrs = %{
      title: title,
      source: :user,
      priority: flags[:priority] || 2,
      context: "",
      acceptance_criteria: [],
      constraints: [],
      dependencies: parse_dependencies(flags[:blocked_by])
    }

    case Issues.create(attrs) do
      {:ok, issue} ->
        IO.puts("Issue #{issue.id} created successfully (quick mode).")
        :ok

      {:error, :cycle_detected} ->
        IO.puts(:stderr, "Error: Adding these dependencies would create a cycle")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to create issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Create an issue in interactive mode with AI elicitation
  defp create_interactive_issue(title, flags) do
    working_dir = flags[:working_dir] || File.cwd!()

    # Verify API key and register provider
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Get open issues for context
    open_issues = Issues.list(status: :open)

    # Build elicitation prompt as initial user message
    priority = flags[:priority]
    elicitation_prompt = ElicitationPrompt.build(title, priority, open_issues)

    # Create system message with elicitation instructions
    system_message = %Deft.Message{
      id: "elicit_sys",
      role: :system,
      content: [%Deft.Message.Text{text: elicitation_prompt}],
      timestamp: DateTime.utc_now()
    }

    # Create a temporary session for elicitation
    session_id = generate_session_id()

    # Build config for elicitation agent (lightweight, tools for issue_draft only)
    agent_config = %{
      model: flags[:model] || "claude-sonnet-4",
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: 10,
      tool_timeout: 30_000,
      bash_timeout: 30_000,
      max_turns: 10,
      tools: [Deft.Tools.UseSkill, Deft.Tools.IssueDraft]
    }

    # Start the elicitation agent with the elicitation prompt as first message
    {:ok, _worker_pid} =
      Deft.Session.Supervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: [system_message],
        project_dir: working_dir
      )

    # Look up the Agent PID from the registry
    [{agent_pid, _}] = Registry.lookup(Deft.Registry, {:agent, session_id})

    # Subscribe to agent events
    Registry.register(Deft.Registry, {:session, session_id}, [])

    IO.puts("Let's create a structured issue for: #{title}")
    IO.puts("")

    # Start the interactive elicitation loop
    case run_elicitation_loop(agent_pid, title, flags) do
      {:ok, draft} ->
        # Present the draft to the user
        present_issue_draft(draft, title, flags)

      {:error, reason} ->
        IO.puts(:stderr, "Error during issue elicitation: #{reason}")
        exit({:shutdown, 1})
    end
  end

  # Run the interactive elicitation loop
  defp run_elicitation_loop(agent_pid, title, flags) do
    # Send initial prompt to start the conversation
    Deft.Agent.prompt(agent_pid, "Please help me create this issue.")

    # Wait for agent to respond and collect the draft
    elicitation_response_loop(agent_pid, nil, title, flags)
  end

  # Loop to handle elicitation conversation
  defp elicitation_response_loop(agent_pid, draft_acc, title, flags) do
    receive do
      {:agent_event, {:text_delta, delta}} ->
        IO.write(delta)
        elicitation_response_loop(agent_pid, draft_acc, title, flags)

      {:agent_event, {:tool_call, tool_name, _tool_id, args}} when tool_name == "issue_draft" ->
        elicitation_response_loop(agent_pid, args, title, flags)

      {:agent_event, {:tool_result, _tool_id, result}} ->
        handle_tool_result(result, agent_pid, draft_acc, title, flags)

      {:agent_event, {:state_change, :idle}} ->
        handle_idle_state(draft_acc, agent_pid, title, flags)

      {:agent_event, {:error, message}} ->
        {:error, message}

      {:agent_event, _other_event} ->
        elicitation_response_loop(agent_pid, draft_acc, title, flags)
    after
      300_000 ->
        {:error, "Timeout waiting for response"}
    end
  end

  # Handle tool result in elicitation loop
  defp handle_tool_result(result, agent_pid, draft_acc, title, flags) do
    case extract_draft_from_result(result) do
      {:ok, draft} ->
        IO.puts("")
        {:ok, draft}

      :not_draft ->
        elicitation_response_loop(agent_pid, draft_acc, title, flags)
    end
  end

  # Handle idle state in elicitation loop
  defp handle_idle_state(draft_acc, agent_pid, title, flags) do
    IO.puts("")

    if draft_acc do
      {:ok, draft_acc}
    else
      handle_user_continuation(agent_pid, title, flags)
    end
  end

  # Handle user continuation input
  defp handle_user_continuation(agent_pid, title, flags) do
    IO.write("deft> ")

    case IO.gets("") do
      :eof ->
        {:error, "Issue creation cancelled"}

      {:error, reason} ->
        {:error, inspect(reason)}

      input ->
        process_continuation_input(input, agent_pid, title, flags)
    end
  end

  # Process continuation input from user
  defp process_continuation_input(input, agent_pid, title, flags) do
    prompt = String.trim(input)

    cond do
      prompt == "" ->
        {:error, "Issue creation cancelled"}

      prompt in ["done", "finish", "save"] ->
        create_default_draft(title, flags)

      true ->
        Deft.Agent.prompt(agent_pid, prompt)
        elicitation_response_loop(agent_pid, nil, title, flags)
    end
  end

  # Create a default draft when user wants to finish without agent completion
  defp create_default_draft(title, flags) do
    {:ok,
     %{
       "title" => title,
       "context" => "",
       "acceptance_criteria" => [],
       "constraints" => [],
       "priority" => flags[:priority] || 2
     }}
  end

  # Extract draft from tool result
  defp extract_draft_from_result(result) do
    case result do
      {:ok, [%Deft.Message.Text{text: text}]} ->
        if String.starts_with?(text, "ISSUE_DRAFT:") do
          json_str = String.replace_prefix(text, "ISSUE_DRAFT:", "")

          case Jason.decode(json_str) do
            {:ok, draft} -> {:ok, draft}
            {:error, _} -> :not_draft
          end
        else
          :not_draft
        end

      _ ->
        :not_draft
    end
  end

  # Present the issue draft and ask for confirmation
  defp present_issue_draft(draft, title, flags) do
    print_draft_header()
    print_draft_details(draft, title)
    print_draft_footer()

    handle_draft_confirmation(draft, title, flags)
  end

  # Print the draft header
  defp print_draft_header do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Issue Draft")
    IO.puts(String.duplicate("=", 70))
    IO.puts("")
  end

  # Print the draft details
  defp print_draft_details(draft, title) do
    IO.puts("Title: #{draft["title"] || title}")
    IO.puts("Priority: #{format_priority(draft["priority"] || 2)}")
    IO.puts("")
    IO.puts("Context:")
    IO.puts("  #{draft["context"] || "(none)"}")
    IO.puts("")

    print_draft_list("Acceptance Criteria:", draft["acceptance_criteria"])
    IO.puts("")
    print_draft_list("Constraints:", draft["constraints"])
  end

  # Print a list field from the draft
  defp print_draft_list(label, items) do
    IO.puts(label)

    case items do
      items when is_list(items) and length(items) > 0 ->
        Enum.each(items, fn item ->
          IO.puts("  - #{item}")
        end)

      _ ->
        IO.puts("  (none)")
    end
  end

  # Print the draft footer
  defp print_draft_footer do
    IO.puts("")
    IO.puts(String.duplicate("=", 70))
    IO.puts("")
  end

  # Handle draft confirmation from user
  defp handle_draft_confirmation(draft, title, flags) do
    IO.puts("Save this issue? (yes/no/edit): ")

    case IO.gets("") |> String.trim() |> String.downcase() do
      answer when answer in ["y", "yes"] ->
        save_issue_from_draft(draft, title, flags)

      answer when answer in ["e", "edit"] ->
        IO.puts("(Edit mode not yet implemented - please re-run the command)")
        :ok

      _ ->
        IO.puts("Issue creation cancelled.")
        :ok
    end
  end

  # Save the issue from the draft
  defp save_issue_from_draft(draft, title, flags) do
    attrs = build_issue_attrs_from_draft(draft, title, flags)

    case Issues.create(attrs) do
      {:ok, issue} ->
        IO.puts("\nIssue #{issue.id} created successfully!")
        :ok

      {:error, :cycle_detected} ->
        IO.puts(:stderr, "Error: Adding these dependencies would create a cycle")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to create issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Build issue attributes from draft
  defp build_issue_attrs_from_draft(draft, title, flags) do
    %{
      title: draft["title"] || title,
      source: :user,
      priority: draft["priority"] || flags[:priority] || 2,
      context: draft["context"] || "",
      acceptance_criteria: draft["acceptance_criteria"] || [],
      constraints: draft["constraints"] || [],
      dependencies: parse_dependencies(flags[:blocked_by])
    }
  end

  # Parse dependencies from --blocked-by flag
  defp parse_dependencies(nil), do: []

  defp parse_dependencies(blocked_by_str) do
    blocked_by_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
