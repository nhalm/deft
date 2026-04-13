defmodule Deft.Session.BranchTest do
  use ExUnit.Case, async: true

  alias Deft.Session.{Branch, Store}
  alias Deft.Session.Entry.{Checkpoint, Message, SessionStart}

  setup do
    # Create a temporary directory for test sessions
    tmp_dir = Path.join(System.tmp_dir!(), "deft_branch_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, working_dir: tmp_dir}
  end

  describe "create/4" do
    test "creates a new session from a checkpoint", %{working_dir: working_dir} do
      # Create a source session
      source_session_id = "sess_source123"
      config = %{model: "claude-sonnet-4-20250514"}

      session_start =
        SessionStart.new(source_session_id, working_dir, "claude-sonnet-4-20250514", config)

      Store.append(source_session_id, session_start, working_dir)

      # Add some messages
      msg1 = %Message{
        type: :message,
        message_id: "msg_1",
        role: :user,
        content: [%{type: "text", text: "Hello"}],
        timestamp: DateTime.utc_now()
      }

      msg2 = %Message{
        type: :message,
        message_id: "msg_2",
        role: :assistant,
        content: [%{type: "text", text: "Hi there"}],
        timestamp: DateTime.utc_now()
      }

      Store.append(source_session_id, msg1, working_dir)
      Store.append(source_session_id, msg2, working_dir)

      # Create a checkpoint after the first two messages (entry_index 2 = after msg2)
      checkpoint = Checkpoint.new("test-checkpoint", 2, "abc123def456")
      Store.append(source_session_id, checkpoint, working_dir)

      # Add another message after the checkpoint
      msg3 = %Message{
        type: :message,
        message_id: "msg_3",
        role: :user,
        content: [%{type: "text", text: "More content"}],
        timestamp: DateTime.utc_now()
      }

      Store.append(source_session_id, msg3, working_dir)

      # Branch from the checkpoint
      new_session_id = "sess_branch456"

      assert {:ok, ^new_session_id} =
               Branch.create(source_session_id, "test-checkpoint", new_session_id, working_dir)

      # Verify the branched session was created
      {:ok, branch_entries} = Store.load(new_session_id, working_dir)

      # Should have: session_start, msg1, msg2 (3 entries total, not including checkpoint or msg3)
      assert length(branch_entries) == 3

      # Check the session_start has branch metadata
      [branch_start | _rest] = branch_entries
      assert %SessionStart{} = branch_start
      assert branch_start.session_id == new_session_id
      assert branch_start.parent_session_id == source_session_id
      assert branch_start.branch_checkpoint == "test-checkpoint"
      assert branch_start.branch_entry_index == 2

      # Check that msg3 is NOT included
      message_ids =
        Enum.flat_map(branch_entries, fn
          %Message{message_id: id} -> [id]
          _ -> []
        end)

      assert "msg_1" in message_ids
      assert "msg_2" in message_ids
      refute "msg_3" in message_ids
    end

    test "returns error when checkpoint not found", %{working_dir: working_dir} do
      # Create a source session without the checkpoint
      source_session_id = "sess_source789"
      config = %{model: "claude-sonnet-4-20250514"}

      session_start =
        SessionStart.new(source_session_id, working_dir, "claude-sonnet-4-20250514", config)

      Store.append(source_session_id, session_start, working_dir)

      # Try to branch from a non-existent checkpoint
      new_session_id = "sess_branch789"

      assert {:error, :checkpoint_not_found} =
               Branch.create(source_session_id, "nonexistent", new_session_id, working_dir)
    end

    test "returns error when source session not found", %{working_dir: working_dir} do
      # Try to branch from a non-existent session
      assert {:error, :enoent} =
               Branch.create("sess_nonexistent", "some-checkpoint", "sess_new", working_dir)
    end

    test "preserves config from original session", %{working_dir: working_dir} do
      # Create a source session with custom config
      source_session_id = "sess_config_test"

      config = %{
        model: "claude-opus-4-6",
        custom_field: "custom_value",
        nested: %{key: "value"}
      }

      session_start = SessionStart.new(source_session_id, working_dir, "claude-opus-4-6", config)
      Store.append(source_session_id, session_start, working_dir)

      # Create checkpoint
      checkpoint = Checkpoint.new("config-checkpoint", 0, "abc123")
      Store.append(source_session_id, checkpoint, working_dir)

      # Branch
      new_session_id = "sess_config_branch"

      assert {:ok, ^new_session_id} =
               Branch.create(source_session_id, "config-checkpoint", new_session_id, working_dir)

      # Load and verify config is preserved
      {:ok, [branch_start | _]} = Store.load(new_session_id, working_dir)
      assert branch_start.config.custom_field == "custom_value"
      assert branch_start.config.nested.key == "value"
    end
  end
end
