defmodule Deft.Session.Store do
  @moduledoc """
  Session persistence to JSONL format.

  Sessions are stored as `~/.deft/sessions/<session_id>.jsonl` where each
  line is a JSON object representing one event in the session timeline.

  ## Entry Types

  See `Deft.Session.Entry` for all supported entry types.

  ## Functions

  - `append/2` - Append an entry to a session file
  - `load/1` - Load all entries from a session file
  - `list/0` - List all sessions with metadata
  """

  alias Deft.Session.Entry

  @sessions_dir Path.expand("~/.deft/sessions")

  @doc """
  Appends an entry to the session JSONL file.

  Creates the sessions directory and file if they don't exist.

  ## Examples

      iex> entry = Entry.SessionStart.new("abc123", "/tmp", "claude-sonnet-4", %{})
      iex> Store.append("abc123", entry)
      :ok
  """
  @spec append(String.t(), Entry.t()) :: :ok | {:error, term()}
  def append(session_id, entry) do
    path = session_path(session_id)

    with :ok <- ensure_sessions_dir(),
         {:ok, json} <- Jason.encode(entry),
         line <- json <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    else
      {:error, reason} = error ->
        require Logger
        Logger.error("Failed to append to session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads all entries from a session JSONL file.

  Returns the entries in chronological order (same order as written).

  ## Examples

      iex> Store.load("abc123")
      {:ok, [%Entry.SessionStart{}, %Entry.Message{}]}

      iex> Store.load("nonexistent")
      {:error, :enoent}
  """
  @spec load(String.t()) :: {:ok, [Entry.t()]} | {:error, term()}
  def load(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} = error ->
        require Logger
        Logger.debug("Failed to load session #{session_id}: #{inspect(reason)}")
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
  - `:om_state` - Latest observation state (if any)
  - `:session_metadata` - Session start metadata

  ## Examples

      iex> Store.resume("abc123")
      {:ok, %{
        messages: [%Deft.Message{}, ...],
        config: %{},
        working_dir: "/tmp",
        model: "claude-sonnet-4",
        om_state: nil,
        session_metadata: %Entry.SessionStart{}
      }}

      iex> Store.resume("nonexistent")
      {:error, :enoent}
  """
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(session_id) do
    case load(session_id) do
      {:ok, entries} ->
        state = reconstruct_state(entries)
        {:ok, state}

      {:error, reason} = error ->
        require Logger
        Logger.debug("Failed to resume session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all sessions with metadata, sorted most-recent-first.

  Returns a list of session metadata maps with:
  - `:session_id` - The session ID
  - `:working_dir` - The working directory
  - `:created_at` - Session creation timestamp
  - `:last_message_at` - Timestamp of last message
  - `:message_count` - Total number of messages
  - `:last_user_prompt` - First line of the last user message

  ## Examples

      iex> Store.list()
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
  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with :ok <- ensure_sessions_dir(),
         {:ok, files} <- File.ls(@sessions_dir) do
      sessions =
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file ->
          session_id = String.replace_suffix(file, ".jsonl", "")
          extract_metadata(session_id)
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

    %{
      messages: messages,
      config: (session_start && session_start.config) || %{},
      working_dir: (session_start && session_start.working_dir) || File.cwd!(),
      model: model,
      om_state: om_state,
      session_metadata: session_start
    }
  end

  defp reconstruct_messages(entries) do
    # Convert message entries back to Deft.Message structs
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

  defp deserialize_content(content) when is_list(content) do
    Enum.map(content, fn
      %{type: "text", text: text} ->
        %Deft.Message.Text{text: text}

      %{type: "tool_use", id: id, name: name, args: args} ->
        %Deft.Message.ToolUse{id: id, name: name, args: args}

      %{
        type: "tool_result",
        tool_use_id: tool_use_id,
        name: name,
        content: content,
        is_error: is_error
      } ->
        %Deft.Message.ToolResult{
          tool_use_id: tool_use_id,
          name: name,
          content: content,
          is_error: is_error
        }

      %{type: "thinking", text: text} ->
        %Deft.Message.Thinking{text: text}

      %{type: "image", media_type: media_type, data: data} ->
        %Deft.Message.Image{media_type: media_type, data: data}

      # Handle string keys as well (from JSON parsing)
      %{"type" => "text", "text" => text} ->
        %Deft.Message.Text{text: text}

      %{"type" => "tool_use", "id" => id, "name" => name, "args" => args} ->
        %Deft.Message.ToolUse{id: id, name: name, args: args}

      %{
        "type" => "tool_result",
        "tool_use_id" => tool_use_id,
        "name" => name,
        "content" => content,
        "is_error" => is_error
      } ->
        %Deft.Message.ToolResult{
          tool_use_id: tool_use_id,
          name: name,
          content: content,
          is_error: is_error
        }

      %{"type" => "thinking", "text" => text} ->
        %Deft.Message.Thinking{text: text}

      %{"type" => "image", "media_type" => media_type, "data" => data} ->
        %Deft.Message.Image{media_type: media_type, data: data}

      _other ->
        # Unknown content type - skip
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

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
      nil -> (session_start && session_start.model) || "claude-sonnet-4"
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

  defp session_path(session_id) do
    Path.join(@sessions_dir, "#{session_id}.jsonl")
  end

  defp ensure_sessions_dir do
    case File.mkdir_p(@sessions_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
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
      generation_count: data.generation_count,
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

  defp extract_metadata(session_id) do
    case load(session_id) do
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
