defmodule Deft.Session do
  @moduledoc """
  Session management and persistence.

  A session represents a conversation history and associated state. Sessions are
  persisted to disk as JSONL files and can be loaded, resumed, and extended.

  This module defines shared types used across the Session subsystem (Store,
  Worker, Supervisor, Entry).
  """

  alias Deft.Config
  alias Deft.Session.Entry.SessionStart
  alias Deft.Session.Store
  alias Deft.Session.Supervisor, as: SessionSupervisor

  @typedoc """
  Unique identifier for a session.

  Session IDs are used to locate session files on disk, reference sessions in
  observational memory, and track which session a tool execution belongs to.
  """
  @type session_id :: String.t()

  @doc """
  Creates a new session in the current working directory.

  Returns the session ID.
  """
  @spec create(keyword()) :: session_id()
  def create(opts \\ []) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    config = Config.load(%{}, working_dir)

    # Generate session ID
    session_id = generate_session_id()

    # Build agent config from loaded config
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
      om_hard_threshold_multiplier: config.om_hard_threshold_multiplier
    }

    # Create the session metadata entry
    config_map = Map.from_struct(config)
    session_start = SessionStart.new(session_id, working_dir, config.model, config_map)
    _ = Store.append(session_id, session_start, working_dir)

    # Start the session process
    {:ok, _worker_pid} =
      SessionSupervisor.start_session(
        session_id: session_id,
        config: agent_config,
        messages: [],
        project_dir: working_dir,
        working_dir: working_dir
      )

    session_id
  end

  defp generate_session_id do
    # Generate a random 8-byte hex string as session ID
    "sess_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
