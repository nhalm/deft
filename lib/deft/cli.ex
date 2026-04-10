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
  - `--loop` - Keep running ready issues (work command only)
  - `--help` / `-h` - Show help
  - `--version` - Show version
  """

  alias Deft.Config
  alias Deft.Git
  alias Deft.Git.Job, as: GitJob
  alias Deft.Issue.ElicitationPrompt
  alias Deft.Issues
  alias Deft.Foreman.Coordinator
  alias Deft.RateLimiter
  alias Deft.Session.Entry.SessionStart
  alias Deft.Session.Store

  @version Mix.Project.config()[:version]

  @doc """
  Main entry point for the CLI.

  Parses arguments, loads configuration, and starts the appropriate mode.
  """
  @spec main([String.t()]) ::
          :ok | {:ok, float()} | {:error, term()} | {:error, :aborted, float()}
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
          loop: :boolean,
          help: :boolean,
          version: :boolean,
          status: :string,
          priority: :integer,
          title: :string,
          blocked_by: :string,
          quick: :boolean,
          edit: :boolean
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
    # Check flags first (higher priority)
    case check_flag_commands(flags) do
      nil -> determine_positional_command(positional, flags)
      command -> command
    end
  end

  # Check for flag-based commands
  defp check_flag_commands(flags) do
    cond do
      flags[:help] -> :help
      flags[:version] -> :version
      flags[:prompt] -> {:non_interactive, flags[:prompt]}
      true -> nil
    end
  end

  # Determine command from positional arguments
  defp determine_positional_command([], _flags) do
    if stdin_piped?() do
      prompt = read_stdin()
      {:non_interactive, prompt}
    else
      :new_session
    end
  end

  defp determine_positional_command(["config"], _flags), do: :config

  defp determine_positional_command(["resume"], _flags) do
    {:error, "Use the web UI to pick a session. Run: deft"}
  end

  defp determine_positional_command(["resume", session_id], _flags) do
    {:resume_session, session_id}
  end

  defp determine_positional_command(["issue" | rest], flags) do
    determine_issue_command(rest, flags)
  end

  defp determine_positional_command(["work" | rest], flags) do
    determine_work_command(rest, flags)
  end

  defp determine_positional_command(positional, _flags) do
    {:error, "Unknown command: #{Enum.join(positional, " ")}"}
  end

  # Determine issue subcommand
  defp determine_issue_command(["create" | title_parts], _flags) do
    if Enum.empty?(title_parts) do
      {:error, "Issue title is required"}
    else
      title = Enum.join(title_parts, " ")
      {:issue_create, title}
    end
  end

  defp determine_issue_command(["show", issue_id], _flags), do: {:issue_show, issue_id}
  defp determine_issue_command(["close", issue_id], _flags), do: {:issue_close, issue_id}
  defp determine_issue_command(["update", issue_id], _flags), do: {:issue_update, issue_id}
  defp determine_issue_command(["list"], _flags), do: :issue_list
  defp determine_issue_command(["ready"], _flags), do: :issue_ready

  defp determine_issue_command(["dep", "add", issue_id], _flags) do
    {:issue_dep_add, issue_id}
  end

  defp determine_issue_command(["dep", "remove", issue_id], _flags) do
    {:issue_dep_remove, issue_id}
  end

  defp determine_issue_command(args, _flags) do
    {:error, "Unknown issue command: issue #{Enum.join(args, " ")}"}
  end

  # Determine work subcommand
  defp determine_work_command([], flags) do
    if flags[:loop], do: :work_loop, else: :work
  end

  defp determine_work_command([issue_id], _flags), do: {:work_issue, issue_id}

  defp determine_work_command(args, _flags) do
    {:error, "Unknown work command: work #{Enum.join(args, " ")}"}
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
    with {:ok, _issue} <- Issues.close(issue_id) do
      IO.puts("Issue #{issue_id} closed successfully.")
      display_newly_unblocked_issues(previously_blocked)
      :ok
    else
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

    # Check for --edit flag
    if flags[:edit] do
      # Interactive mode: start elicitation session with existing issue
      update_interactive_issue(issue_id, flags)
    else
      # Direct update mode: use flags to update specific fields
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

  defp execute_command(:work_loop, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Load config to get cost ceiling
    working_dir = flags[:working_dir] || File.cwd!()
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    IO.puts("Starting work loop...")
    IO.puts("Cost ceiling: $#{config.work_cost_ceiling}")

    approval_mode =
      if flags[:auto_approve_all],
        do: "fully autonomous (--auto-approve-all)",
        else: "approve every plan"

    IO.puts("Approval mode: #{approval_mode}")
    IO.puts("Press Ctrl+C to stop gracefully.")
    IO.puts("")

    # Run the work loop
    run_work_loop(flags, config, 0.0, 1)
  end

  defp execute_command(:work, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get ready issues (sorted by priority, then created_at)
    ready_issues = Issues.ready()

    case ready_issues do
      [] ->
        IO.puts("No ready issues found.")
        :ok

      [issue | _] ->
        IO.puts("Starting work on issue #{issue.id}: #{issue.title}")
        run_work_on_issue(issue, flags)
    end
  end

  defp execute_command({:work_issue, issue_id}, flags) do
    # Ensure Issues GenServer is started
    ensure_issues_started(flags)

    # Get the specific issue
    case Issues.get(issue_id) do
      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})

      {:ok, issue} ->
        # Verify it's open
        if issue.status != :open do
          IO.puts(:stderr, "Error: Issue #{issue_id} is not open (status: #{issue.status})")
          exit({:shutdown, 1})
        end

        IO.puts("Starting work on issue #{issue.id}: #{issue.title}")
        run_work_on_issue(issue, flags)
    end
  end

  defp execute_command({:resume_session, session_id}, flags) do
    # Clean up orphaned git artifacts from crashed jobs
    working_dir = flags[:working_dir] || File.cwd!()
    _ = cleanup_git_orphans(working_dir, flags[:auto_approve_all])

    # Load the session state
    with {:ok, state} <- Store.resume(session_id, working_dir) do
      display_session_summary(session_id, state)
      resume_session_with_state(session_id, state, flags)
    else
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

    # Clean up orphaned git artifacts from crashed jobs
    _ = cleanup_git_orphans(working_dir, flags[:auto_approve_all])

    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Open browser to web UI without creating a session
    # Session management handled by web UI (spec section 5.5)
    start_web_ui()
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
    _ = create_session(session_id, working_dir, config)
    agent_pid = start_agent(session_id, working_dir, config)

    # Subscribe to agent events
    _ = Registry.register(Deft.Registry, {:session, session_id}, [])

    # Open output handle and run
    output_handle = open_output_handle(flags[:output])
    Deft.Agent.prompt(agent_pid, prompt)
    result = non_interactive_loop(output_handle)

    # Clean up
    _ = close_output_handle(output_handle)
    result
  end

  defp execute_command({:error, message}, _flags) do
    IO.puts(:stderr, "Error: #{message}")
    IO.puts(:stderr, "\nRun 'deft --help' for usage information.")
    exit({:shutdown, 1})
  end

  # Display newly unblocked issues after closing a blocker
  defp display_newly_unblocked_issues(previously_blocked) do
    newly_unblocked = find_newly_unblocked(previously_blocked)

    unless Enum.empty?(newly_unblocked) do
      IO.puts("")
      IO.puts("Newly unblocked issues:")

      Enum.each(newly_unblocked, fn issue ->
        IO.puts("  - #{issue.id}: #{issue.title}")
      end)
    end
  end

  # Resume a session with loaded state (interactive or non-interactive)
  defp resume_session_with_state(session_id, state, flags) do
    case flags[:prompt] do
      nil -> resume_interactive_session(session_id, state, flags)
      prompt -> continue_session_non_interactive(session_id, state, prompt, flags)
    end
  end

  # Resume session in interactive mode
  defp resume_interactive_session(session_id, state, flags) do
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, state.working_dir)

    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    _agent_pid =
      start_agent(session_id, state.working_dir, config, %{
        initial_messages: state.messages,
        initial_session_cost: state.session_cost,
        om_snapshot: state.om_snapshot
      })

    _ = Registry.register(Deft.Registry, {:session, session_id}, [])
    IO.puts("Deft session #{session_id} resumed.")
    start_web_ui(session_id)
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

    # Start agent with existing messages, cost, and OM snapshot from the session
    agent_pid =
      start_agent(session_id, working_dir, config, %{
        initial_messages: state.messages,
        initial_session_cost: state.session_cost,
        om_snapshot: state.om_snapshot
      })

    # Subscribe to agent events
    _ = Registry.register(Deft.Registry, {:session, session_id}, [])

    # Open output handle and run
    output_handle = open_output_handle(flags[:output])
    Deft.Agent.prompt(agent_pid, prompt)
    result = non_interactive_loop(output_handle)

    # Clean up
    _ = close_output_handle(output_handle)
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
      deft work                           Pick highest-priority ready issue and run as job
      deft work <id>                      Run a specific issue as a job
      deft work --loop                    Keep running ready issues until queue empty or cost ceiling
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
      --loop                    Keep running ready issues (work command only)
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
    Store.append(session_id, session_start, working_dir)
  end

  # Start the Agent process for a session
  defp start_agent(session_id, working_dir, config, opts \\ %{}) do
    initial_messages = Map.get(opts, :initial_messages, [])
    initial_session_cost = Map.get(opts, :initial_session_cost, 0.0)
    om_snapshot = Map.get(opts, :om_snapshot, nil)

    agent_config = %{
      model: config.model,
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: config.turn_limit,
      tool_timeout: config.tool_timeout,
      bash_timeout: config.bash_timeout,
      max_turns: config.turn_limit,
      tools: [
        Deft.Tools.Read,
        Deft.Tools.Write,
        Deft.Tools.Edit,
        Deft.Tools.Bash,
        Deft.Tools.Grep,
        Deft.Tools.Find,
        Deft.Tools.Ls,
        Deft.Tools.UseSkill,
        Deft.Tools.IssueCreate
      ],
      om_enabled: config.om_enabled,
      om_message_token_threshold: config.om_message_token_threshold,
      om_observation_token_threshold: config.om_observation_token_threshold,
      om_buffer_interval: config.om_buffer_interval,
      om_buffer_tail_retention: config.om_buffer_tail_retention,
      om_hard_threshold_multiplier: config.om_hard_threshold_multiplier,
      work_cost_ceiling: config.work_cost_ceiling,
      job_initial_concurrency: config.job_initial_concurrency,
      job_max_leads: config.job_max_leads
    }

    {:ok, _worker_pid} =
      Deft.Session.Supervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: initial_messages,
        session_cost: initial_session_cost,
        om_snapshot: om_snapshot,
        project_dir: working_dir
      )

    # Look up the Foreman agent PID from the registry
    [{agent_pid, _}] = Registry.lookup(Deft.ProcessRegistry, {:foreman, session_id})
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

  # Ensure working tree is clean before starting a job
  # Prompts user to stash if dirty (unless auto_approve is true)
  # Per git-strategy spec section 1
  defp ensure_clean_working_tree(job_id, auto_approve) do
    case Git.cmd(["status", "--porcelain"]) do
      {"", 0} ->
        # Working tree is clean
        :ok

      {output, 0} when byte_size(output) > 0 ->
        # Working tree has uncommitted changes
        handle_dirty_working_tree_cli(job_id, output, auto_approve)

      {error_output, exit_code} ->
        IO.puts(:stderr, "Failed to check git status: #{error_output}")
        {:error, {:git_status_failed, exit_code}}
    end
  end

  # Handle dirty working tree by prompting user or failing in auto mode
  defp handle_dirty_working_tree_cli(job_id, status_output, auto_approve) do
    if auto_approve do
      # In auto-approve mode, we can't stash - fail immediately
      IO.puts(:stderr, """
      Working tree has uncommitted changes (--auto-approve-all mode):

      #{status_output}

      Please commit or stash your changes before starting a job.
      """)

      {:error, :dirty_working_tree}
    else
      # Interactive mode - prompt user
      IO.puts("""
      Warning: Working tree has uncommitted changes:

      #{status_output}

      You should stash your changes before starting a job.
      This prevents conflicts with the job's work.
      """)

      IO.write("Stash changes and continue? [y/N]: ")
      response = IO.gets("")
      handle_stash_response_cli(job_id, response)
    end
  end

  # Handle user response to stash prompt
  defp handle_stash_response_cli(job_id, response) do
    case response do
      :eof ->
        # Non-interactive environment (e.g., tests with no stdin)
        IO.puts("\nJob creation cancelled (no input available).\n")
        {:error, :dirty_working_tree}

      input when is_binary(input) ->
        case String.trim(input) |> String.downcase() do
          answer when answer in ["y", "yes"] ->
            perform_stash_cli(job_id)

          _ ->
            IO.puts("\nJob creation cancelled.\n")
            {:error, :dirty_working_tree}
        end
    end
  end

  # Perform the actual git stash operation
  defp perform_stash_cli(job_id) do
    IO.puts("\nStashing changes...")
    stash_message = "Deft job creation: #{job_id}"

    case Git.cmd(["stash", "push", "-m", stash_message]) do
      {output, 0} ->
        IO.puts(output)
        IO.puts("Changes stashed successfully. Continuing with job creation.\n")
        :ok

      {error_output, _exit_code} ->
        IO.puts(:stderr, "Failed to stash changes: #{error_output}")
        IO.puts("\nFailed to stash changes. Please resolve manually and restart the job.\n")
        {:error, :stash_failed}
    end
  end

  # Detect if stdin is piped (not a TTY)
  defp stdin_piped? do
    case :io.columns() do
      {:ok, _} -> !IO.ANSI.enabled?()
      {:error, _} -> true
    end
  end

  # Read prompt from stdin
  defp read_stdin do
    :stdio
    |> IO.stream(:line)
    |> Enum.to_list()
    |> Enum.join()
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
  @spec exit_with_error(String.t()) :: no_return()
  defp exit_with_error(message) do
    IO.puts(:stderr, message)
    exit({:shutdown, 1})
  end

  # Display a list of issues in tabular format
  defp display_issue_list(issues) when issues == [] do
    IO.puts("No issues found.")
  end

  defp display_issue_list(issues) do
    widths = calculate_column_widths(issues)
    print_issue_table_header(widths)
    print_issue_table_rows(issues, widths)
  end

  # Calculate column widths for issue table
  defp calculate_column_widths(issues) do
    id_width =
      max(
        2,
        Enum.max_by(issues, &String.length(&1.id), fn -> %{id: "id"} end).id |> String.length()
      )

    status_width =
      max(6, Enum.max_by(issues, &status_length/1, fn -> %{status: :open} end) |> status_length())

    %{id: id_width, priority: 8, status: status_width, title: 60}
  end

  # Print the header row of the issue table
  defp print_issue_table_header(widths) do
    header = [
      String.pad_trailing("ID", widths.id),
      String.pad_trailing("Priority", widths.priority),
      String.pad_trailing("Status", widths.status),
      "Title"
    ]

    IO.puts(Enum.join(header, "  "))

    separator_width = widths.id + widths.priority + widths.status + widths.title + 6
    IO.puts(String.duplicate("-", separator_width))
  end

  # Print each issue row in the table
  defp print_issue_table_rows(issues, widths) do
    Enum.each(issues, fn issue ->
      row = [
        String.pad_trailing(issue.id, widths.id),
        String.pad_trailing(format_priority_short(issue.priority), widths.priority),
        String.pad_trailing(format_status(issue.status), widths.status),
        truncate_title(issue.title, widths.title)
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
    print_issue_header(issue)
    print_issue_context(issue.context)
    print_issue_acceptance_criteria(issue.acceptance_criteria)
    print_issue_constraints(issue.constraints)
    print_issue_dependencies(issue.dependencies)
    print_issue_timestamps(issue)
  end

  # Print issue header fields
  defp print_issue_header(issue) do
    IO.puts("Issue: #{issue.id}")
    IO.puts("Title: #{issue.title}")
    IO.puts("Status: #{issue.status}")
    IO.puts("Priority: #{format_priority(issue.priority)}")
    IO.puts("Source: #{issue.source}")
    IO.puts("")
  end

  # Print issue context section
  defp print_issue_context(context) do
    IO.puts("Context:")
    IO.puts(if context == "", do: "  (none)", else: "  #{context}")
    IO.puts("")
  end

  # Print issue acceptance criteria section
  defp print_issue_acceptance_criteria(criteria) do
    IO.puts("Acceptance Criteria:")

    if Enum.empty?(criteria) do
      IO.puts("  (none)")
    else
      Enum.each(criteria, fn criterion -> IO.puts("  - #{criterion}") end)
    end

    IO.puts("")
  end

  # Print issue constraints section
  defp print_issue_constraints(constraints) do
    IO.puts("Constraints:")

    if Enum.empty?(constraints) do
      IO.puts("  (none)")
    else
      Enum.each(constraints, fn constraint -> IO.puts("  - #{constraint}") end)
    end

    IO.puts("")
  end

  # Print issue dependencies section
  defp print_issue_dependencies(dependencies) do
    IO.puts("Dependencies:")

    if Enum.empty?(dependencies) do
      IO.puts("  (none)")
    else
      Enum.each(dependencies, fn dep_id -> IO.puts("  - #{dep_id}") end)
    end

    IO.puts("")
  end

  # Print issue timestamps
  defp print_issue_timestamps(issue) do
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

      {:error, {:blocker_not_found, id}} ->
        IO.puts(:stderr, "Error: Blocker issue '#{id}' does not exist")
        exit({:shutdown, 1})

      {:error, {:blockers_not_found, ids}} ->
        IO.puts(:stderr, "Error: Blocker issues do not exist: #{Enum.join(ids, ", ")}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to create issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Create an issue in interactive mode with AI elicitation
  defp create_interactive_issue(title, flags) do
    working_dir = flags[:working_dir] || File.cwd!()
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    open_issues = Issues.list(status: :open)
    elicitation_prompt = ElicitationPrompt.build(title, flags[:priority], open_issues)

    agent_pid = start_elicitation_agent(working_dir, flags, elicitation_prompt)

    IO.puts("Let's create a structured issue for: #{title}")
    IO.puts("")

    case run_elicitation_loop(agent_pid, title, flags) do
      {:ok, draft} -> present_issue_draft(draft, title, flags)
      {:error, reason} -> handle_elicitation_error(reason)
    end
  end

  # Start an elicitation agent for interactive issue creation
  defp start_elicitation_agent(working_dir, flags, elicitation_prompt) do
    system_message = %Deft.Message{
      id: "elicit_sys",
      role: :system,
      content: [%Deft.Message.Text{text: elicitation_prompt}],
      timestamp: DateTime.utc_now()
    }

    session_id = generate_session_id()

    agent_config = %{
      model: flags[:model] || "claude-sonnet-4-20250514",
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: 10,
      tool_timeout: 30_000,
      bash_timeout: 30_000,
      max_turns: 10,
      tools: [Deft.Tools.UseSkill, Deft.Tools.IssueDraft]
    }

    {:ok, _worker_pid} =
      Deft.Session.Supervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: [system_message],
        project_dir: working_dir
      )

    [{agent_pid, _}] = Registry.lookup(Deft.ProcessRegistry, {:agent, session_id})
    _ = Registry.register(Deft.Registry, {:session, session_id}, [])
    agent_pid
  end

  # Handle elicitation error
  @spec handle_elicitation_error(term()) :: no_return()
  defp handle_elicitation_error(reason) do
    IO.puts(:stderr, "Error during issue elicitation: #{reason}")
    exit({:shutdown, 1})
  end

  defp update_interactive_issue(issue_id, flags) do
    working_dir = flags[:working_dir] || File.cwd!()

    with {:ok, issue} <- Issues.get(issue_id) do
      update_issue_with_elicitation(issue, issue_id, working_dir, flags)
    else
      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue_id}")
        exit({:shutdown, 1})
    end
  end

  # Update an issue using AI elicitation
  defp update_issue_with_elicitation(issue, issue_id, working_dir, flags) do
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    open_issues = Issues.list(status: :open)
    elicitation_prompt = ElicitationPrompt.build_for_edit(issue, open_issues)

    agent_pid = start_elicitation_agent(working_dir, flags, elicitation_prompt)

    IO.puts("Let's refine issue #{issue_id}: #{issue.title}")
    IO.puts("")

    case run_update_elicitation_loop(agent_pid, issue) do
      {:ok, draft} -> present_issue_update_draft(draft, issue, flags)
      {:error, reason} -> handle_elicitation_error(reason)
    end
  end

  # Run the interactive elicitation loop for updating
  defp run_update_elicitation_loop(agent_pid, issue) do
    # Send initial prompt to start the conversation
    Deft.Agent.prompt(agent_pid, "Please help me refine this issue.")

    # Wait for agent to respond and collect the draft
    elicitation_response_loop(agent_pid, nil, issue.title, %{})
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

      {:agent_event, {:tool_call_done, %{id: _tool_id, args: args}}} ->
        updated_draft = handle_tool_call_done(args, draft_acc)
        elicitation_response_loop(agent_pid, updated_draft, title, flags)

      {:agent_event, {:tool_execution_complete, %{name: "issue_draft", result: result}}} ->
        handle_tool_result(result, agent_pid, draft_acc, title, flags)

      {:agent_event, {:tool_execution_complete, _}} ->
        elicitation_response_loop(agent_pid, draft_acc, title, flags)

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

  # Handle tool call done event - check if it's an issue_draft tool
  defp handle_tool_call_done(args, draft_acc) do
    is_draft =
      Map.has_key?(args, "title") and Map.has_key?(args, "context") and
        Map.has_key?(args, "acceptance_criteria")

    if is_draft, do: args, else: draft_acc
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
  defp extract_draft_from_result({:ok, [%Deft.Message.Text{text: text}]}) do
    extract_draft_from_text(text)
  end

  defp extract_draft_from_result(_result), do: :not_draft

  # Extract draft from text content
  defp extract_draft_from_text(text) do
    if String.starts_with?(text, "ISSUE_DRAFT:") do
      json_str = String.replace_prefix(text, "ISSUE_DRAFT:", "")

      case Jason.decode(json_str) do
        {:ok, draft} -> {:ok, draft}
        {:error, _} -> :not_draft
      end
    else
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
        edit_issue_draft(draft, title, flags)

      _ ->
        IO.puts("Issue creation cancelled.")
        :ok
    end
  end

  # Edit the draft by restarting the elicitation session with pre-populated fields
  defp edit_issue_draft(draft, title, flags) do
    working_dir = flags[:working_dir] || File.cwd!()

    # Verify API key and register provider
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Get open issues for context
    open_issues = Issues.list(status: :open)

    # Build elicitation prompt for editing with existing draft fields
    elicitation_prompt = ElicitationPrompt.build_for_draft_edit(draft, title, open_issues)

    # Set up the elicitation agent
    agent_pid = setup_elicitation_agent(elicitation_prompt, working_dir, flags)

    IO.puts("\nLet's refine the issue draft...")
    IO.puts("")

    # Start the interactive elicitation loop
    case run_elicitation_loop(agent_pid, title, flags) do
      {:ok, updated_draft} ->
        # Present the updated draft to the user
        present_issue_draft(updated_draft, title, flags)

      {:error, reason} ->
        IO.puts(:stderr, "Error during issue elicitation: #{reason}")
        exit({:shutdown, 1})
    end
  end

  # Set up and start the elicitation agent, returning the agent PID
  defp setup_elicitation_agent(elicitation_prompt, working_dir, flags) do
    system_message = %Deft.Message{
      id: "elicit_sys_edit",
      role: :system,
      content: [%Deft.Message.Text{text: elicitation_prompt}],
      timestamp: DateTime.utc_now()
    }

    session_id = generate_session_id()

    agent_config = build_elicitation_agent_config(working_dir, flags)

    {:ok, _worker_pid} =
      Deft.Session.Supervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: [system_message],
        project_dir: working_dir
      )

    [{agent_pid, _}] = Registry.lookup(Deft.ProcessRegistry, {:agent, session_id})
    _ = Registry.register(Deft.Registry, {:session, session_id}, [])

    agent_pid
  end

  # Build config for elicitation agent
  defp build_elicitation_agent_config(working_dir, flags) do
    %{
      model: flags[:model] || "claude-sonnet-4-20250514",
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: 10,
      tool_timeout: 30_000,
      bash_timeout: 30_000,
      max_turns: 10,
      tools: [Deft.Tools.UseSkill, Deft.Tools.IssueDraft]
    }
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

      {:error, {:blocker_not_found, id}} ->
        IO.puts(:stderr, "Error: Blocker issue '#{id}' does not exist")
        exit({:shutdown, 1})

      {:error, {:blockers_not_found, ids}} ->
        IO.puts(:stderr, "Error: Blocker issues do not exist: #{Enum.join(ids, ", ")}")
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

  # Present the issue update draft to the user
  defp present_issue_update_draft(draft, issue, flags) do
    print_draft_header()
    print_draft_details(draft, issue.title)
    print_draft_footer()

    handle_update_draft_confirmation(draft, issue, flags)
  end

  # Handle draft confirmation for update
  defp handle_update_draft_confirmation(draft, issue, flags) do
    IO.puts("Save these changes? (yes/no): ")

    case IO.gets("") |> String.trim() |> String.downcase() do
      answer when answer in ["y", "yes"] ->
        save_issue_from_update_draft(draft, issue, flags)

      _ ->
        IO.puts("Issue update cancelled.")
        :ok
    end
  end

  # Save the issue from the update draft
  defp save_issue_from_update_draft(draft, issue, _flags) do
    attrs = build_issue_attrs_from_update_draft(draft, issue)

    case Issues.update(issue.id, attrs) do
      {:ok, updated_issue} ->
        IO.puts("\nIssue #{issue.id} updated successfully!")
        IO.puts("")
        display_issue(updated_issue)
        :ok

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Issue not found: #{issue.id}")
        exit({:shutdown, 1})

      {:error, :cycle_detected} ->
        IO.puts(:stderr, "Error: Adding these dependencies would create a cycle")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to update issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Build issue attributes from update draft
  defp build_issue_attrs_from_update_draft(draft, issue) do
    %{
      title: draft["title"] || issue.title,
      priority: draft["priority"] || issue.priority,
      context: draft["context"] || issue.context,
      acceptance_criteria: draft["acceptance_criteria"] || issue.acceptance_criteria,
      constraints: draft["constraints"] || issue.constraints
    }
  end

  # Start the web UI and block until shutdown
  # Open browser to web UI without a session (session picker)
  defp start_web_ui do
    # Read the actual port from the pidfile
    port = read_server_port()
    url = "http://localhost:#{port}"

    # Print URL first
    IO.puts("\nDeft running at #{url}")
    IO.puts("Press Ctrl+C to stop.\n")

    # Block until Ctrl+C (BEAM handles shutdown)
    Process.sleep(:infinity)
  end

  # Open browser to web UI with a specific session
  defp start_web_ui(session_id) do
    # Read the actual port from the pidfile
    port = read_server_port()
    url = "http://localhost:#{port}?session=#{session_id}"

    # Print URL first
    IO.puts("\nDeft running at #{url}")
    IO.puts("Press Ctrl+C to stop.\n")

    # Block until Ctrl+C (BEAM handles shutdown)
    Process.sleep(:infinity)
  end

  # Read the server port from the pidfile
  defp read_server_port do
    pidfile_path = Deft.Project.project_dir() |> Path.join("server.pid")

    case File.read(pidfile_path) do
      {:ok, content} ->
        content
        |> String.trim()
        |> String.to_integer()

      {:error, _} ->
        # Fallback to default port if pidfile doesn't exist
        4000
    end
  end

  # Run the work loop - keeps picking and running ready issues
  defp run_work_loop(flags, config, cumulative_cost, iteration) do
    # Check for SIGINT
    receive do
      {:signal, :sigint} ->
        IO.puts("\nReceived Ctrl+C. Shutting down gracefully...")
        :ok
    after
      0 ->
        # No SIGINT, continue with the loop
        continue_work_loop(flags, config, cumulative_cost, iteration)
    end
  end

  # Continue the work loop - check for ready issues and process them
  defp continue_work_loop(flags, config, cumulative_cost, iteration) do
    case Issues.ready() do
      [] -> complete_work_loop(cumulative_cost)
      [issue | _] -> process_next_job(issue, flags, config, cumulative_cost, iteration)
    end
  end

  # Complete the work loop when no more ready issues
  defp complete_work_loop(cumulative_cost) do
    IO.puts("No more ready issues. Loop complete.")
    IO.puts("Total cost: $#{Float.round(cumulative_cost, 2)}")
    :ok
  end

  # Process next job in work loop
  defp process_next_job(issue, flags, config, cumulative_cost, iteration) do
    if cumulative_cost >= config.work_cost_ceiling do
      report_cost_ceiling_reached(config.work_cost_ceiling, cumulative_cost)
    else
      run_next_job(issue, flags, config, cumulative_cost, iteration)
    end
  end

  # Report that cost ceiling was reached
  defp report_cost_ceiling_reached(ceiling, cumulative_cost) do
    IO.puts("Cost ceiling reached ($#{ceiling}). Total cost: $#{Float.round(cumulative_cost, 2)}")

    :ok
  end

  # Run the next job and handle result
  defp run_next_job(issue, flags, config, cumulative_cost, iteration) do
    IO.puts("\n--- Job #{iteration} ---")
    IO.puts("Starting work on issue #{issue.id}: #{issue.title}")
    IO.puts("Cumulative cost so far: $#{Float.round(cumulative_cost, 2)}")
    IO.puts("")

    case run_work_on_issue_with_cost(issue, flags) do
      {:ok, job_cost} -> handle_job_success(job_cost, cumulative_cost, flags, config, iteration)
      {:error, :aborted, job_cost} -> handle_job_abort(job_cost, cumulative_cost)
      {:error, reason} -> handle_job_failure(reason, cumulative_cost)
    end
  end

  # Handle successful job completion
  defp handle_job_success(job_cost, cumulative_cost, flags, config, iteration) do
    new_cumulative_cost = cumulative_cost + job_cost
    IO.puts("Job cost: $#{Float.round(job_cost, 2)}")
    IO.puts("Total cost: $#{Float.round(new_cumulative_cost, 2)}")
    run_work_loop(flags, config, new_cumulative_cost, iteration + 1)
  end

  # Handle job abort
  defp handle_job_abort(job_cost, cumulative_cost) do
    new_cumulative_cost = cumulative_cost + job_cost
    IO.puts("Job aborted by user.")
    IO.puts("Total cost: $#{Float.round(new_cumulative_cost, 2)}")
    :ok
  end

  # Handle job failure
  @spec handle_job_failure(term(), float()) :: no_return()
  defp handle_job_failure(reason, cumulative_cost) do
    IO.puts(:stderr, "Job failed: #{inspect(reason)}")
    IO.puts("Total cost: $#{Float.round(cumulative_cost, 2)}")
    exit({:shutdown, 1})
  end

  # Run a Foreman job for an issue and return the cost
  defp run_work_on_issue_with_cost(issue, flags) do
    # Run the issue and get the actual cost from the RateLimiter
    run_work_on_issue(issue, flags)
  end

  # Get cumulative cost from rate limiter and clean it up
  defp get_cost_and_cleanup_rate_limiter(rate_limiter_pid, job_id) do
    cost =
      if Process.alive?(rate_limiter_pid) do
        RateLimiter.get_cumulative_cost(job_id)
      else
        0.0
      end

    if Process.alive?(rate_limiter_pid) do
      GenServer.stop(rate_limiter_pid)
    end

    cost
  end

  # Run a Foreman job for an issue
  defp run_work_on_issue(issue, flags) do
    working_dir = flags[:working_dir] || File.cwd!()
    cli_flags = build_cli_flags(flags)
    config = Config.load(cli_flags, working_dir)

    # Verify API key and register provider
    verify_api_key()
    :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

    # Set issue status to in_progress
    set_issue_in_progress(issue)

    # Generate session ID
    session_id = "session_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    # Verify working tree is clean before starting the session
    # This is required by git-strategy spec section 1 - prompt user to stash if dirty
    verify_clean_tree_or_abort(session_id, issue, flags[:auto_approve_all])

    # Start the session and wait for completion
    start_job_and_wait(session_id, issue, working_dir, config, flags)
  end

  # Set issue status to in_progress
  defp set_issue_in_progress(issue) do
    case Issues.update(issue.id, %{status: :in_progress}) do
      {:ok, _issue} ->
        IO.puts("Issue #{issue.id} status set to in_progress")

      {:error, reason} ->
        IO.puts(:stderr, "Error: Failed to update issue status: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Verify working tree is clean or abort session creation
  defp verify_clean_tree_or_abort(session_id, issue, auto_approve) do
    case ensure_clean_working_tree(session_id, auto_approve) do
      :ok ->
        :ok

      {:error, :dirty_working_tree} ->
        Issues.update(issue.id, %{status: :open})
        IO.puts(:stderr, "Session creation cancelled - working tree has uncommitted changes")
        exit({:shutdown, 1})

      {:error, reason} ->
        Issues.update(issue.id, %{status: :open})
        IO.puts(:stderr, "Error: Failed to verify working tree: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Start session and wait for completion
  defp start_job_and_wait(session_id, issue, working_dir, config, flags) do
    issue_prompt = build_issue_prompt(issue)

    agent_config = %{
      model: config.model,
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: config.turn_limit,
      tool_timeout: config.tool_timeout,
      bash_timeout: config.bash_timeout,
      max_turns: config.turn_limit,
      tools: [Deft.Tools.UseSkill, Deft.Tools.IssueCreate],
      auto_approve_all: flags[:auto_approve_all],
      work_cost_ceiling: config.work_cost_ceiling,
      job_keep_failed_branches: config.job_keep_failed_branches,
      job_max_leads: config.job_max_leads,
      job_max_runners_per_lead: config.job_max_runners_per_lead,
      job_research_timeout: config.job_research_timeout,
      job_runner_timeout: config.job_runner_timeout,
      job_foreman_model: config.job_foreman_model,
      job_lead_model: config.job_lead_model,
      job_runner_model: config.job_runner_model,
      job_research_runner_model: config.job_research_runner_model,
      job_max_duration: config.job_max_duration,
      job_test_command: config.job_test_command,
      job_squash_on_complete: config.job_squash_on_complete,
      job_initial_concurrency: config.job_initial_concurrency
    }

    case Deft.Session.Supervisor.start_session(
           session_id: session_id,
           config: agent_config,
           prompt: issue_prompt,
           working_dir: working_dir,
           cli_pid: self()
         ) do
      {:ok, _session_supervisor_pid} ->
        foreman_pid = get_foreman_pid(session_id)
        ref = Process.monitor(foreman_pid)
        result = wait_for_job_completion(foreman_pid, ref)
        cost = get_job_cost(session_id)

        case handle_job_result(result, issue, session_id, cost) do
          :ok -> {:ok, cost}
          other -> other
        end

      {:error, reason} ->
        cost = get_job_cost(session_id)
        Issues.update(issue.id, %{status: :open})
        IO.puts(:stderr, "Error: Failed to start session: #{inspect(reason)}")
        IO.puts("Job cost: $#{Float.round(cost, 2)}")
        exit({:shutdown, 1})
    end
  end

  # Get Foreman.Coordinator PID from registry
  defp get_foreman_pid(job_id) do
    case Registry.lookup(Deft.ProcessRegistry, {:foreman_coordinator, job_id}) do
      [{pid, _}] -> pid
      [] -> raise "Foreman.Coordinator not found in registry for job #{job_id}"
    end
  end

  # Get cost from rate limiter and clean it up
  defp get_job_cost(job_id) do
    case Registry.lookup(Deft.ProcessRegistry, {:rate_limiter, job_id}) do
      [{rate_limiter_pid, _}] -> get_cost_and_cleanup_rate_limiter(rate_limiter_pid, job_id)
      [] -> 0.0
    end
  end

  # Build a prompt from issue structured fields
  defp build_issue_prompt(issue) do
    Jason.encode!(%{
      id: issue.id,
      title: issue.title,
      priority: issue.priority,
      context: issue.context,
      acceptance_criteria: issue.acceptance_criteria,
      constraints: issue.constraints
    })
  end

  # Wait for job completion by monitoring Foreman process
  defp wait_for_job_completion(foreman_pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^foreman_pid, reason} ->
        handle_foreman_down(reason)

      {:plan_approval_needed, plan} ->
        handle_plan_approval(foreman_pid, plan)
        wait_for_job_completion(foreman_pid, ref)

      {:job_message, message} ->
        display_job_message(message)
        wait_for_job_completion(foreman_pid, ref)

      {:signal, :sigint} ->
        handle_sigint_shutdown(foreman_pid, ref)
    after
      3_600_000 ->
        handle_job_timeout(foreman_pid, ref)
    end
  end

  # Handle Foreman process termination
  defp handle_foreman_down(:normal), do: {:ok, :completed}
  defp handle_foreman_down(:shutdown), do: {:error, :aborted}
  defp handle_foreman_down(other), do: {:error, other}

  # Display a message from the Foreman
  defp display_job_message(message) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("JOB MESSAGE")
    IO.puts(String.duplicate("=", 80))
    IO.puts("\n#{message}\n")
    IO.puts(String.duplicate("=", 80))
  end

  # Handle SIGINT graceful shutdown
  defp handle_sigint_shutdown(foreman_pid, ref) do
    IO.puts("\nReceived Ctrl+C. Sending shutdown to Foreman...")
    Coordinator.abort(foreman_pid)

    receive do
      {:DOWN, ^ref, :process, ^foreman_pid, _reason} ->
        IO.puts("Foreman shut down gracefully.")
        {:error, :sigint_shutdown}
    after
      5_000 -> handle_sigint_timeout(foreman_pid, ref)
    end
  end

  # Handle SIGINT shutdown timeout
  defp handle_sigint_timeout(foreman_pid, ref) do
    IO.puts(
      "Warning: Foreman did not shut down within 5 seconds. Issue may be left at :in_progress."
    )

    Process.demonitor(ref, [:flush])

    if Process.alive?(foreman_pid) do
      :gen_statem.stop(foreman_pid)
    end

    {:error, :sigint_timeout}
  end

  # Handle job timeout (1 hour)
  defp handle_job_timeout(foreman_pid, ref) do
    Process.demonitor(ref, [:flush])

    if Process.alive?(foreman_pid) do
      :gen_statem.stop(foreman_pid)
    end

    {:error, :timeout}
  end

  # Handle plan approval request from Foreman
  defp handle_plan_approval(foreman_pid, plan) do
    # Display the plan
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("WORK PLAN")
    IO.puts(String.duplicate("=", 80))
    IO.puts("\n#{plan.raw_plan}\n")
    IO.puts(String.duplicate("=", 80))

    # Prompt for approval
    IO.puts("\nApprove this plan?")
    IO.puts("  [y] Yes, proceed with this plan")
    IO.puts("  [n] No, request a revision")
    IO.write("\nYour choice: ")

    case IO.gets("") |> String.trim() |> String.downcase() do
      "y" ->
        IO.puts("Plan approved. Execution will begin...")
        Coordinator.approve_plan(foreman_pid)

      "n" ->
        IO.puts("Plan rejected. Foreman will revise...")
        Coordinator.reject_plan(foreman_pid)

      _ ->
        IO.puts("Invalid choice. Please enter 'y' or 'n'.")
        handle_plan_approval(foreman_pid, plan)
    end
  end

  # Handle the result of a job
  defp handle_job_result({:ok, :completed}, issue, job_id, _cost) do
    case Issues.close(issue.id, job_id) do
      {:ok, _issue} -> handle_successful_job_completion(issue, job_id)
      {:error, reason} -> handle_job_close_error(reason)
    end
  end

  defp handle_job_result({:error, :sigint_shutdown}, issue, _job_id, cost) do
    # SIGINT received and Foreman shut down gracefully
    # Rollback the issue status to :open
    IO.puts("\nJob aborted by user (Ctrl+C).")

    case Issues.update(issue.id, %{status: :open}) do
      {:ok, _issue} ->
        IO.puts("Issue #{issue.id} status rolled back to open.")

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Warning: Failed to rollback issue status: #{inspect(reason)}. Issue may be left at :in_progress."
        )
    end

    # Return aborted error to stop the work loop
    {:error, :aborted, cost}
  end

  defp handle_job_result({:error, :sigint_timeout}, issue, _job_id, cost) do
    # SIGINT received but Foreman did not shut down within 5 seconds
    IO.puts(:stderr, "\nJob aborted by user (Ctrl+C), but shutdown timed out.")

    # Try to manually rollback the issue status
    case Issues.update(issue.id, %{status: :open}) do
      {:ok, _issue} ->
        IO.puts(
          :stderr,
          "Warning: Issue #{issue.id} status manually rolled back to open due to shutdown timeout."
        )

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Warning: Failed to rollback issue status: #{inspect(reason)}. Issue may be left at :in_progress."
        )
    end

    # Return aborted error to stop the work loop
    {:error, :aborted, cost}
  end

  defp handle_job_result({:error, :aborted}, issue, _job_id, cost) do
    # Non-SIGINT abort (e.g., Foreman :shutdown exit)
    IO.puts("\nJob aborted.")

    # Roll back the issue status to :open
    case Issues.update(issue.id, %{status: :open}) do
      {:ok, _issue} ->
        IO.puts("Issue #{issue.id} status rolled back to open.")

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Warning: Failed to rollback issue status: #{inspect(reason)}. Issue may be left at :in_progress."
        )
    end

    # Report the job cost
    IO.puts("Job cost: $#{Float.round(cost, 2)}")

    # Return aborted error with cost so the work loop can include it in cumulative total
    {:error, :aborted, cost}
  end

  defp handle_job_result({:error, reason}, issue, _job_id, cost) do
    # Job failed - revert issue to open
    case Issues.update(issue.id, %{status: :open}) do
      {:ok, _issue} ->
        IO.puts(:stderr, "\nJob failed: #{inspect(reason)}")
        IO.puts(:stderr, "Issue #{issue.id} status reverted to open.")

      {:error, update_reason} ->
        IO.puts(
          :stderr,
          "Error: Job failed and failed to revert issue status: #{inspect(update_reason)}"
        )
    end

    # Report the job cost
    IO.puts("Job cost: $#{Float.round(cost, 2)}")

    # Return error to stop the work loop
    {:error, reason}
  end

  # Handle successful job completion and display unblocked issues
  defp handle_successful_job_completion(issue, job_id) do
    IO.puts("\nJob #{job_id} completed successfully!")
    IO.puts("Issue #{issue.id} closed.")

    all_issues = Issues.list(status: [:open, :in_progress])
    previously_blocked = find_issues_blocked_by(all_issues, issue.id)
    display_newly_unblocked_issues(previously_blocked)

    :ok
  end

  # Handle error when closing issue after job completion
  defp handle_job_close_error(reason) do
    IO.puts(:stderr, "Warning: Failed to close issue: #{inspect(reason)}")
    :ok
  end
end
