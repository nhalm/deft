defmodule Deft.Session.Store do
  @moduledoc """
  Session persistence to JSONL format.

  There are two kinds of sessions, both using the same JSONL format:

  **User sessions** — conversations between the user and Deft:
  - Storage: `~/.deft/projects/<path-encoded-repo>/sessions/<session_id>.jsonl`
  - Listed in the web UI session picker. Resumable by the user.
  - Use `append/3`, `load/2`, `resume/2`, and `list/1` for user sessions.

  **Agent sessions** — internal LLM conversation history for orchestrated sub-agents:
  - Storage: `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/foreman_session.jsonl`
    and `lead_<id>_session.jsonl`
  - Not listed in the session picker. Not directly resumable.
  - Use `append_foreman_session/3`, `append_lead_session/4`, or `append_to_path/2`.

  ## Entry Types

  See `Deft.Session.Entry` for all supported entry types.

  ## Functions

  **User sessions:**
  - `append/3` - Append an entry to a user session file
  - `load/2` - Load all entries from a session file
  - `resume/2` - Resume a session and reconstruct state
  - `list/1` - List all user sessions with metadata

  **Agent sessions:**
  - `append_to_path/2` - Append an entry to a custom path
  - `foreman_session_path/2` - Get the path for a Foreman session
  - `lead_session_path/3` - Get the path for a Lead session
  - `append_foreman_session/3` - Append to a Foreman session
  - `append_lead_session/4` - Append to a Lead session
  """

  alias Deft.OM.State, as: OMState
  alias Deft.Session.Entry
  alias Deft.Project

  @doc """
  Appends an entry to the session JSONL file.

  Creates the sessions directory and file if they don't exist.

  ## Examples

      iex> entry = Entry.SessionStart.new("abc123", "/tmp", "claude-sonnet-4-20250514", %{})
      iex> Store.append("abc123", entry, "/tmp")
      :ok
  """
  @spec append(Deft.Session.session_id(), Entry.t(), String.t() | nil) :: :ok | {:error, term()}
  def append(session_id, entry, working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()
    path = session_path(session_id, working_dir)

    with :ok <- ensure_sessions_dir(working_dir),
         {:ok, json} <- Jason.encode(entry),
         line <- json <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    else
      {:error, reason} = error ->
        require Logger
        Logger.error("[Session] Failed to append to session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Appends an entry to a session JSONL file at a custom path.

  Creates parent directories if they don't exist. Used for job orchestration
  sessions (Foreman and Lead sessions) that live in the job directory instead
  of the default sessions directory.

  ## Examples

      iex> entry = Entry.SessionStart.new("abc123", "/tmp", "claude-sonnet-4-20250514", %{})
      iex> Store.append_to_path("/tmp/job_123/foreman_session.jsonl", entry)
      :ok
  """
  @spec append_to_path(String.t(), Entry.t()) :: :ok | {:error, term()}
  def append_to_path(path, entry) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(entry),
         line <- json <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    else
      {:error, reason} = error ->
        require Logger
        Logger.error("[Session] Failed to append to session file #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Returns the path for a Foreman agent session file.

  Foreman sessions are stored in the jobs directory:
  `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/foreman_session.jsonl`

  ## Examples

      iex> Store.foreman_session_path("job_123", "/tmp")
      "~/.deft/projects/-tmp/jobs/job_123/foreman_session.jsonl"
  """
  @spec foreman_session_path(String.t(), String.t() | nil) :: String.t()
  def foreman_session_path(job_id, working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()
    jobs_dir = Project.jobs_dir(working_dir)
    Path.join([jobs_dir, job_id, "foreman_session.jsonl"])
  end

  @doc """
  Returns the path for a Lead agent session file.

  Lead sessions are stored in the jobs directory:
  `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/lead_<lead_id>_session.jsonl`

  ## Examples

      iex> Store.lead_session_path("job_123", "lead_1", "/tmp")
      "~/.deft/projects/-tmp/jobs/job_123/lead_lead_1_session.jsonl"
  """
  @spec lead_session_path(String.t(), String.t(), String.t() | nil) :: String.t()
  def lead_session_path(job_id, lead_id, working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()
    jobs_dir = Project.jobs_dir(working_dir)
    Path.join([jobs_dir, job_id, "lead_#{lead_id}_session.jsonl"])
  end

  @doc """
  Appends an entry to a Foreman agent session.

  Convenience wrapper around `append_to_path/2` that uses the correct path
  for Foreman sessions.

  ## Examples

      iex> entry = Entry.SessionStart.new("job_123", "/tmp", "claude-haiku-4.5", %{})
      iex> Store.append_foreman_session("job_123", entry, "/tmp")
      :ok
  """
  @dialyzer {:nowarn_function, append_foreman_session: 3}
  @spec append_foreman_session(String.t(), Entry.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def append_foreman_session(job_id, entry, working_dir \\ nil) do
    path = foreman_session_path(job_id, working_dir)
    append_to_path(path, entry)
  end

  @doc """
  Appends an entry to a Lead agent session.

  Convenience wrapper around `append_to_path/2` that uses the correct path
  for Lead sessions.

  ## Examples

      iex> entry = Entry.SessionStart.new("lead_1", "/tmp", "claude-haiku-4.5", %{})
      iex> Store.append_lead_session("job_123", "lead_1", entry, "/tmp")
      :ok
  """
  @dialyzer {:nowarn_function, append_lead_session: 4}
  @spec append_lead_session(String.t(), String.t(), Entry.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def append_lead_session(job_id, lead_id, entry, working_dir \\ nil) do
    path = lead_session_path(job_id, lead_id, working_dir)
    append_to_path(path, entry)
  end

  @doc """
  Loads all entries from a session JSONL file.

  Returns the entries in chronological order (same order as written).

  ## Examples

      iex> Store.load("abc123", "/tmp")
      {:ok, [%Entry.SessionStart{}, %Entry.Message{}]}

      iex> Store.load("nonexistent", "/tmp")
      {:error, :enoent}
  """
  @spec load(Deft.Session.session_id(), String.t() | nil) :: {:ok, [Entry.t()]} | {:error, term()}
  def load(session_id, working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()
    path = session_path(session_id, working_dir)

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Resumes a session by reconstructing conversation state from entries.

  Returns a map containing:
  - `:messages` - List of reconstructed Deft.Message structs
  - `:config` - Configuration map from session_start
  - `:working_dir` - Working directory from session_start
  - `:model` - Model name from session_start (or latest model_change)
  - `:om_snapshot` - Latest observation snapshot from separate _om.jsonl file (if any)
  - `:session_cost` - Cumulative cost from latest cost entry (or 0.0)
  - `:session_metadata` - Session start metadata

  ## Examples

      iex> Store.resume("abc123", "/tmp")
      {:ok, %{
        messages: [%Deft.Message{}, ...],
        config: %{},
        working_dir: "/tmp",
        model: "claude-sonnet-4-20250514",
        om_snapshot: nil,
        session_cost: 0.05,
        session_metadata: %Entry.SessionStart{}
      }}

      iex> Store.resume("nonexistent", "/tmp")
      {:error, :enoent}
  """
  @spec resume(Deft.Session.session_id(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def resume(session_id, working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()

    case load(session_id, working_dir) do
      {:ok, entries} ->
        require Logger
        Logger.info("[Session] Session resumed: #{session_id}, #{length(entries)} entries")

        state = reconstruct_state(entries)

        # Load OM snapshot from separate _om.jsonl file or fall back to observation entries (spec section 1.3)
        om_snapshot =
          case OMState.load_latest_snapshot(session_id, working_dir) do
            {:ok, nil} -> state.om_state
            {:ok, snapshot} -> snapshot
            {:error, _reason} -> state.om_state
          end

        # Replace om_state with om_snapshot from the separate file or observation entries from main JSONL
        state = Map.put(state, :om_snapshot, om_snapshot)

        {:ok, state}

      {:error, reason} = error ->
        require Logger
        Logger.debug("[Session] Failed to resume session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all sessions with metadata for the given working directory, sorted most-recent-first.

  Returns a list of session metadata maps with:
  - `:session_id` - The session ID
  - `:working_dir` - The working directory
  - `:created_at` - Session creation timestamp
  - `:last_message_at` - Timestamp of last message
  - `:message_count` - Total number of messages
  - `:last_user_prompt` - First line of the last user message

  ## Examples

      iex> Store.list("/tmp")
      {:ok, [
        %{
          session_id: "abc123",
          working_dir: "/tmp",
          created_at: ~U[2026-03-16 12:00:00Z],
          last_message_at: ~U[2026-03-16 12:05:00Z],
          message_count: 10,
          last_user_prompt: "Help me debug this function"
        }
      ]}
  """
  @spec list(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list(working_dir \\ nil) do
    working_dir = working_dir || File.cwd!()
    sessions_dir = Project.sessions_dir(working_dir)

    with :ok <- ensure_sessions_dir(working_dir),
         {:ok, files} <- File.ls(sessions_dir) do
      sessions =
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.reject(&String.ends_with?(&1, "_om.jsonl"))
        |> Enum.map(fn file ->
          session_id = String.replace_suffix(file, ".jsonl", "")
          extract_metadata(session_id, working_dir)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.last_message_at, {:desc, DateTime})

      {:ok, sessions}
    end
  end

  # Private helpers

  defp reconstruct_state(entries) do
    # Extract session metadata
    session_start = find_session_start(entries)

    # Reconstruct messages from message entries
    messages = reconstruct_messages(entries)

    # Find the latest model (from session_start or model_change entries)
    model = find_latest_model(entries, session_start)

    # Find the latest observation state
    om_state = find_latest_observation(entries)

    # Find the latest cost entry
    session_cost = find_latest_cost(entries)

    %{
      messages: messages,
      config: (session_start && session_start.config) || %{},
      working_dir: (session_start && session_start.working_dir) || File.cwd!(),
      model: model,
      om_state: om_state,
      session_cost: session_cost,
      session_metadata: session_start
    }
  end

  defp reconstruct_messages(entries) do
    # Convert message entries to Deft.Message structs
    # Skip Entry.ToolResult — it's metadata-only (stores duration_ms)
    # Tool results are already in the user message saved by save_unsaved_messages
    entries
    |> Enum.filter(fn
      %Entry.Message{} -> true
      _ -> false
    end)
    |> Enum.map(&entry_to_message/1)
  end

  defp entry_to_message(%Entry.Message{} = entry) do
    %Deft.Message{
      id: entry.message_id,
      role: entry.role,
      content: deserialize_content(entry.content),
      timestamp: entry.timestamp
    }
  end

  defp entry_to_message(%Entry.ToolResult{} = entry) do
    %Deft.Message{
      id: "tool_result_#{entry.tool_call_id}",
      role: :user,
      content: [
        %Deft.Message.ToolResult{
          tool_use_id: entry.tool_call_id,
          name: entry.name,
          content: entry.result,
          is_error: entry.is_error
        }
      ],
      timestamp: entry.timestamp
    }
  end

  defp deserialize_content(content) when is_list(content) do
    content
    |> Enum.map(&deserialize_content_block/1)
    |> Enum.reject(&is_nil/1)
  end

  # Text content with atom keys
  defp deserialize_content_block(%{type: "text", text: text}) do
    %Deft.Message.Text{text: text}
  end

  # Text content with string keys
  defp deserialize_content_block(%{"type" => "text", "text" => text}) do
    %Deft.Message.Text{text: text}
  end

  # Tool use with atom keys
  defp deserialize_content_block(%{type: "tool_use", id: id, name: name, args: args}) do
    %Deft.Message.ToolUse{id: id, name: name, args: args}
  end

  # Tool use with string keys
  defp deserialize_content_block(%{
         "type" => "tool_use",
         "id" => id,
         "name" => name,
         "args" => args
       }) do
    %Deft.Message.ToolUse{id: id, name: name, args: args}
  end

  # Tool result with atom keys
  defp deserialize_content_block(%{
         type: "tool_result",
         tool_use_id: tool_use_id,
         name: name,
         content: content,
         is_error: is_error
       }) do
    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: name,
      content: content,
      is_error: is_error
    }
  end

  # Tool result with string keys
  defp deserialize_content_block(%{
         "type" => "tool_result",
         "tool_use_id" => tool_use_id,
         "name" => name,
         "content" => content,
         "is_error" => is_error
       }) do
    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: name,
      content: content,
      is_error: is_error
    }
  end

  # Thinking content with atom keys
  defp deserialize_content_block(%{type: "thinking", text: text}) do
    %Deft.Message.Thinking{text: text}
  end

  # Thinking content with string keys
  defp deserialize_content_block(%{"type" => "thinking", "text" => text}) do
    %Deft.Message.Thinking{text: text}
  end

  # Image content with atom keys
  defp deserialize_content_block(%{type: "image", media_type: media_type, data: data} = content) do
    %Deft.Message.Image{
      media_type: media_type,
      data: data,
      filename: Map.get(content, :filename)
    }
  end

  # Image content with string keys
  defp deserialize_content_block(
         %{"type" => "image", "media_type" => media_type, "data" => data} = content
       ) do
    %Deft.Message.Image{
      media_type: media_type,
      data: data,
      filename: Map.get(content, "filename")
    }
  end

  # Unknown content type - skip
  defp deserialize_content_block(_other), do: nil

  defp find_latest_model(entries, session_start) do
    # Find the most recent model_change entry, or use session_start model
    latest_change =
      entries
      |> Enum.reverse()
      |> Enum.find(fn
        %Entry.ModelChange{} -> true
        _ -> false
      end)

    case latest_change do
      %Entry.ModelChange{to_model: model} -> model
      nil -> (session_start && session_start.model) || "claude-sonnet-4-20250514"
    end
  end

  defp find_latest_observation(entries) do
    # Find the most recent observation entry
    entries
    |> Enum.reverse()
    |> Enum.find(fn
      %Entry.Observation{} -> true
      _ -> false
    end)
  end

  defp find_latest_cost(entries) do
    # Find the most recent cost entry and return cumulative_cost, or 0.0 if not found
    entries
    |> Enum.reverse()
    |> Enum.find(fn
      %Entry.Cost{} -> true
      _ -> false
    end)
    |> case do
      %Entry.Cost{cumulative_cost: cost} -> cost
      nil -> 0.0
    end
  end

  defp session_path(session_id, working_dir) do
    sessions_dir = Project.sessions_dir(working_dir)
    Path.join(sessions_dir, "#{session_id}.jsonl")
  end

  defp ensure_sessions_dir(working_dir) do
    Project.ensure_project_dirs(working_dir)
  end

  defp parse_entry(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, data} -> deserialize_entry(data)
      {:error, _reason} -> nil
    end
  end

  # Deserialize JSON data into typed entry structs
  defp deserialize_entry(%{type: type} = data) when type in ["session_start", :session_start] do
    %Entry.SessionStart{
      type: :session_start,
      session_id: data.session_id,
      created_at: parse_datetime(data.created_at),
      working_dir: data.working_dir,
      model: data.model,
      config: data.config
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["message", :message] do
    %Entry.Message{
      type: :message,
      message_id: data.message_id,
      role: parse_atom(data.role, [:user, :assistant, :system]),
      content: data.content,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["tool_result", :tool_result] do
    %Entry.ToolResult{
      type: :tool_result,
      tool_call_id: data.tool_call_id,
      name: data.name,
      result: data.result,
      duration_ms: data.duration_ms,
      is_error: data.is_error,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["model_change", :model_change] do
    %Entry.ModelChange{
      type: :model_change,
      from_model: data.from_model,
      to_model: data.to_model,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["observation", :observation] do
    %Entry.Observation{
      type: :observation,
      active_observations: data.active_observations,
      observation_tokens: data.observation_tokens,
      observed_message_ids: data.observed_message_ids,
      pending_message_tokens: data[:pending_message_tokens] || 0,
      generation_count: data.generation_count,
      last_observed_at: parse_datetime_or_nil(data[:last_observed_at]),
      activation_epoch: data[:activation_epoch] || 0,
      calibration_factor: data[:calibration_factor] || 4.0,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["compaction", :compaction] do
    %Entry.Compaction{
      type: :compaction,
      summary: data.summary,
      messages_removed: data.messages_removed,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["cost", :cost] do
    %Entry.Cost{
      type: :cost,
      cumulative_cost: data.cumulative_cost,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(_unknown), do: nil

  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime_or_nil(nil), do: nil

  defp parse_datetime_or_nil(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime_or_nil(%DateTime{} = dt), do: dt

  defp parse_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: :user
  end

  defp parse_atom(value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: :user
  rescue
    ArgumentError -> :user
  end

  defp parse_atom(_, _), do: :user

  defp extract_metadata(session_id, working_dir) do
    case load(session_id, working_dir) do
      {:ok, entries} ->
        build_session_metadata(session_id, entries)

      {:error, _} ->
        nil
    end
  end

  defp build_session_metadata(session_id, entries) do
    session_start = find_session_start(entries)
    messages = filter_messages(entries)
    last_message = List.last(messages)
    last_user_prompt = extract_last_user_prompt(messages)

    case session_start do
      %Entry.SessionStart{} = start ->
        %{
          session_id: session_id,
          working_dir: start.working_dir,
          created_at: start.created_at,
          last_message_at: (last_message && last_message.timestamp) || start.created_at,
          message_count: length(messages),
          last_user_prompt: last_user_prompt
        }

      nil ->
        nil
    end
  end

  defp find_session_start(entries) do
    Enum.find(entries, fn
      %Entry.SessionStart{} -> true
      _ -> false
    end)
  end

  defp filter_messages(entries) do
    Enum.filter(entries, fn
      %Entry.Message{} -> true
      _ -> false
    end)
  end

  defp extract_last_user_prompt(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :user end)
    |> extract_prompt_text()
  end

  defp extract_prompt_text(nil), do: ""

  defp extract_prompt_text(msg) do
    msg.content
    |> Enum.find_value(fn
      %Deft.Message.Text{text: text} -> text
      %{type: "text", text: text} -> text
      _ -> nil
    end)
    |> format_prompt_preview()
  end

  defp format_prompt_preview(nil), do: ""

  defp format_prompt_preview(text) do
    text
    |> String.split("\n")
    |> List.first()
    |> String.slice(0..80)
  end
end
