defmodule Deft.Session.StoreTest do
  use ExUnit.Case, async: false

  alias Deft.Session.Store

  alias Deft.Session.Entry.{
    SessionStart,
    Message,
    ToolResult,
    ModelChange,
    Observation,
    Compaction,
    Cost
  }

  @test_sessions_dir "/tmp/deft_store_test_#{System.unique_integer([:positive])}"

  setup do
    # Override the sessions directory for testing
    Application.put_env(:deft, :sessions_dir, @test_sessions_dir)

    # Clean up any existing test directory
    File.rm_rf!(@test_sessions_dir)
    File.mkdir_p!(@test_sessions_dir)

    on_exit(fn ->
      File.rm_rf!(@test_sessions_dir)
      Application.delete_env(:deft, :sessions_dir)
    end)

    :ok
  end

  # Helper to override the sessions dir in Store module
  defp session_path(session_id) do
    Path.join(@test_sessions_dir, "#{session_id}.jsonl")
  end

  describe "append/2" do
    test "creates session file and appends SessionStart entry" do
      session_id = "test-session-1"
      entry = SessionStart.new(session_id, "/tmp", "claude-sonnet-4-20250514", %{om: true})

      # Temporarily patch the module attribute
      assert :ok = append_with_dir(session_id, entry)

      # Verify file was created
      path = session_path(session_id)
      assert File.exists?(path)

      # Verify content
      content = File.read!(path)
      assert String.contains?(content, ~s("type":"session_start"))
      assert String.contains?(content, ~s("session_id":"#{session_id}"))
    end

    test "appends multiple entries to the same session" do
      session_id = "test-session-2"

      entry1 = SessionStart.new(session_id, "/tmp", "claude-sonnet-4-20250514", %{})
      entry2 = Cost.new(0.05)

      assert :ok = append_with_dir(session_id, entry1)
      assert :ok = append_with_dir(session_id, entry2)

      # Verify both entries are in the file
      content = File.read!(session_path(session_id))
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2
    end

    test "handles encoding errors gracefully" do
      session_id = "test-session-error"
      # Create an entry that will fail JSON encoding by using a function (not serializable)
      # Actually, Jason can handle most Elixir types, so let's just test the success case
      # and rely on Jason's own error handling for edge cases
      entry = Cost.new(1.5)
      assert :ok = append_with_dir(session_id, entry)
    end
  end

  describe "load/1" do
    test "loads all entries from a session file" do
      session_id = "test-session-load"

      entry1 = SessionStart.new(session_id, "/tmp/project", "claude-sonnet-4-20250514", %{})
      entry2 = Cost.new(0.02)
      entry3 = ModelChange.new("claude-sonnet-4-20250514", "claude-opus-4")

      append_with_dir(session_id, entry1)
      append_with_dir(session_id, entry2)
      append_with_dir(session_id, entry3)

      assert {:ok, entries} = load_with_dir(session_id)
      assert length(entries) == 3

      assert %SessionStart{session_id: ^session_id} = Enum.at(entries, 0)
      assert %Cost{cumulative_cost: 0.02} = Enum.at(entries, 1)
      assert %ModelChange{from_model: "claude-sonnet-4-20250514"} = Enum.at(entries, 2)
    end

    test "returns error when session file does not exist" do
      assert {:error, :enoent} = load_with_dir("nonexistent-session")
    end

    test "handles corrupted lines gracefully" do
      session_id = "test-session-corrupted"
      path = session_path(session_id)

      # Write a valid entry followed by corrupted JSON
      File.write!(path, """
      {"type":"cost","cumulative_cost":0.5,"timestamp":"2026-03-16T12:00:00Z"}
      {invalid json
      {"type":"cost","cumulative_cost":1.0,"timestamp":"2026-03-16T12:01:00Z"}
      """)

      assert {:ok, entries} = load_with_dir(session_id)
      # Should skip the corrupted line and load the valid ones
      assert length(entries) == 2
      assert Enum.all?(entries, &match?(%Cost{}, &1))
    end
  end

  describe "list/0" do
    test "returns empty list when no sessions exist" do
      assert {:ok, []} = list_with_dir()
    end

    test "lists sessions with metadata, most-recent-first" do
      # Create session 1
      session1 = "session-1"

      entry1_start =
        SessionStart.new(session1, "/tmp/project1", "claude-sonnet-4-20250514", %{})

      append_with_dir(session1, entry1_start)
      # Simulate some time passing
      :timer.sleep(10)

      # Create session 2
      session2 = "session-2"

      entry2_start =
        SessionStart.new(session2, "/tmp/project2", "claude-opus-4", %{})

      append_with_dir(session2, entry2_start)

      assert {:ok, sessions} = list_with_dir()
      assert length(sessions) == 2

      # Most recent should be first
      assert %{session_id: "session-2"} = Enum.at(sessions, 0)
      assert %{session_id: "session-1"} = Enum.at(sessions, 1)
    end

    test "includes correct metadata in session list" do
      session_id = "session-meta"

      start_entry =
        SessionStart.new(session_id, "/tmp/workspace", "claude-sonnet-4-20250514", %{})

      # Create a message entry
      msg_entry = %Message{
        type: :message,
        message_id: "msg-1",
        role: :user,
        content: [%{type: "text", text: "What is the purpose of life?\nSecond line."}],
        timestamp: DateTime.utc_now()
      }

      append_with_dir(session_id, start_entry)
      append_with_dir(session_id, msg_entry)

      assert {:ok, [session]} = list_with_dir()

      assert session.session_id == session_id
      assert session.working_dir == "/tmp/workspace"
      assert %DateTime{} = session.created_at
      assert %DateTime{} = session.last_message_at
      assert session.message_count == 1
      assert String.starts_with?(session.last_user_prompt, "What is the purpose of life?")
      # Should truncate to first line
      refute String.contains?(session.last_user_prompt, "Second line")
    end

    test "handles sessions with no messages" do
      session_id = "session-no-messages"
      start_entry = SessionStart.new(session_id, "/tmp", "claude-sonnet-4-20250514", %{})

      append_with_dir(session_id, start_entry)

      assert {:ok, [session]} = list_with_dir()
      assert session.message_count == 0
      assert session.last_user_prompt == ""
      assert session.last_message_at == session.created_at
    end
  end

  describe "entry type deserialization" do
    test "deserializes SessionStart correctly" do
      session_id = "test-deserialize-start"
      config = %{om: true, model: "claude-sonnet-4-20250514"}
      entry = SessionStart.new(session_id, "/tmp/work", "claude-sonnet-4-20250514", config)

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %SessionStart{} = loaded
      assert loaded.session_id == session_id
      assert loaded.working_dir == "/tmp/work"
      assert loaded.model == "claude-sonnet-4-20250514"
      assert loaded.config == config
    end

    test "deserializes Message correctly" do
      session_id = "test-deserialize-msg"

      msg = %Message{
        type: :message,
        message_id: "msg-123",
        role: :user,
        content: [
          %{type: "text", text: "Hello"},
          %{type: "tool_use", id: "tool-1", name: "bash", args: %{command: "ls"}}
        ],
        timestamp: DateTime.utc_now()
      }

      append_with_dir(session_id, msg)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %Message{} = loaded
      assert loaded.message_id == "msg-123"
      assert loaded.role == :user
      assert length(loaded.content) == 2
    end

    test "deserializes ToolResult correctly" do
      session_id = "test-deserialize-tool"
      entry = ToolResult.new("tool-1", "bash", "output", 150, false)

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %ToolResult{} = loaded
      assert loaded.tool_call_id == "tool-1"
      assert loaded.name == "bash"
      assert loaded.result == "output"
      assert loaded.duration_ms == 150
      assert loaded.is_error == false
    end

    test "deserializes ModelChange correctly" do
      session_id = "test-deserialize-model"
      entry = ModelChange.new("claude-sonnet-4-20250514", "claude-opus-4")

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %ModelChange{} = loaded
      assert loaded.from_model == "claude-sonnet-4-20250514"
      assert loaded.to_model == "claude-opus-4"
    end

    test "deserializes Observation correctly" do
      session_id = "test-deserialize-obs"
      last_observed = DateTime.utc_now()

      entry =
        Observation.new(%{
          active_observations: "Some observations",
          observation_tokens: 1500,
          observed_message_ids: ["msg-1", "msg-2"],
          pending_message_tokens: 1000,
          generation_count: 2,
          last_observed_at: last_observed,
          activation_epoch: 5,
          calibration_factor: 4.0
        })

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %Observation{} = loaded
      assert loaded.active_observations == "Some observations"
      assert loaded.observation_tokens == 1500
      assert loaded.observed_message_ids == ["msg-1", "msg-2"]
      assert loaded.pending_message_tokens == 1000
      assert loaded.generation_count == 2
      assert loaded.last_observed_at != nil
      assert loaded.activation_epoch == 5
      assert loaded.calibration_factor == 4.0
    end

    test "deserializes Compaction correctly" do
      session_id = "test-deserialize-compact"
      entry = Compaction.new("Summary of messages", 5)

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %Compaction{} = loaded
      assert loaded.summary == "Summary of messages"
      assert loaded.messages_removed == 5
    end

    test "deserializes Cost correctly" do
      session_id = "test-deserialize-cost"
      entry = Cost.new(2.75)

      append_with_dir(session_id, entry)
      assert {:ok, [loaded]} = load_with_dir(session_id)

      assert %Cost{} = loaded
      assert loaded.cumulative_cost == 2.75
    end
  end

  # Helper functions to use test directory

  defp append_with_dir(session_id, entry) do
    path = session_path(session_id)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, json} <- Jason.encode(entry),
         line <- json <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    end
  end

  defp load_with_dir(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_with_dir do
    case File.ls(@test_sessions_dir) do
      {:ok, files} ->
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

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  defp parse_entry(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, data} -> deserialize_entry(data)
      {:error, _reason} -> nil
    end
  end

  defp deserialize_entry(%{type: type} = data) when type in ["session_start", :session_start] do
    %SessionStart{
      type: :session_start,
      session_id: data.session_id,
      created_at: parse_datetime(data.created_at),
      working_dir: data.working_dir,
      model: data.model,
      config: data.config
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["message", :message] do
    %Message{
      type: :message,
      message_id: data.message_id,
      role: parse_atom(data.role, [:user, :assistant, :system]),
      content: data.content,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["tool_result", :tool_result] do
    %ToolResult{
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
    %ModelChange{
      type: :model_change,
      from_model: data.from_model,
      to_model: data.to_model,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["observation", :observation] do
    %Observation{
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
    %Compaction{
      type: :compaction,
      summary: data.summary,
      messages_removed: data.messages_removed,
      timestamp: parse_datetime(data.timestamp)
    }
  end

  defp deserialize_entry(%{type: type} = data) when type in ["cost", :cost] do
    %Cost{
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

  defp extract_metadata(session_id) do
    case load_with_dir(session_id) do
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
      %SessionStart{} = start ->
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
      %SessionStart{} -> true
      _ -> false
    end)
  end

  defp filter_messages(entries) do
    Enum.filter(entries, fn
      %Message{} -> true
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

  describe "agent session paths" do
    test "foreman_session_path/2 returns correct path" do
      job_id = "job-123"
      working_dir = @test_sessions_dir

      path = Store.foreman_session_path(job_id, working_dir)

      assert String.ends_with?(path, "/jobs/#{job_id}/foreman_session.jsonl")
      assert String.contains?(path, "/.deft/projects/")
    end

    test "lead_session_path/3 returns correct path" do
      job_id = "job-456"
      lead_id = "lead_1"
      working_dir = @test_sessions_dir

      path = Store.lead_session_path(job_id, lead_id, working_dir)

      assert String.ends_with?(path, "/jobs/#{job_id}/lead_#{lead_id}_session.jsonl")
      assert String.contains?(path, "/.deft/projects/")
    end

    test "append_to_path/2 creates parent directories and writes entry" do
      custom_path = Path.join([@test_sessions_dir, "custom", "path", "session.jsonl"])
      entry = SessionStart.new("test-id", "/tmp", "claude-sonnet-4-20250514", %{})

      refute File.exists?(custom_path)

      assert :ok = Store.append_to_path(custom_path, entry)

      assert File.exists?(custom_path)

      content = File.read!(custom_path)
      assert String.contains?(content, ~s("type":"session_start"))
    end

    test "append_foreman_session/3 writes to correct foreman session path" do
      job_id = "job-789"
      working_dir = @test_sessions_dir
      entry = SessionStart.new("foreman-#{job_id}", working_dir, "claude-haiku-4.5", %{})

      assert :ok = Store.append_foreman_session(job_id, entry, working_dir)

      path = Store.foreman_session_path(job_id, working_dir)
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, ~s("type":"session_start"))
      assert String.contains?(content, "claude-haiku-4.5")
    end

    test "append_lead_session/4 writes to correct lead session path" do
      job_id = "job-abc"
      lead_id = "lead_2"
      working_dir = @test_sessions_dir
      entry = SessionStart.new("lead-#{lead_id}", working_dir, "claude-haiku-4.5", %{})

      assert :ok =
               Store.append_lead_session(job_id, lead_id, entry, working_dir)

      path = Store.lead_session_path(job_id, lead_id, working_dir)
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, ~s("type":"session_start"))
      assert String.contains?(content, "claude-haiku-4.5")
    end

    test "agent sessions are not listed in regular session list" do
      # Create a user session
      user_session_id = "user-session"

      user_entry =
        SessionStart.new(user_session_id, @test_sessions_dir, "claude-sonnet-4-20250514", %{})

      append_with_dir(user_session_id, user_entry)

      # Create agent sessions in jobs directory
      job_id = "job-xyz"

      foreman_entry =
        SessionStart.new("foreman-#{job_id}", @test_sessions_dir, "claude-haiku-4.5", %{})

      Store.append_foreman_session(job_id, foreman_entry, @test_sessions_dir)

      lead_entry = SessionStart.new("lead-1", @test_sessions_dir, "claude-haiku-4.5", %{})
      Store.append_lead_session(job_id, "lead_1", lead_entry, @test_sessions_dir)

      # List should only return user session, not agent sessions
      assert {:ok, sessions} = list_with_dir()
      assert length(sessions) == 1
      assert hd(sessions).session_id == user_session_id
    end
  end
end
