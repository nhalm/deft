defmodule Deft.Session.BranchTest do
  use ExUnit.Case, async: true

  alias Deft.Session.{Branch, Store}
  alias Deft.Session.Entry.{Checkpoint, Message, SessionStart}

  setup do
    # Create a temporary directory for test sessions
    tmp_dir = Path.join(System.tmp_dir!(), "deft_branch_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    # Initialize a git repository for testing git branch creation
    System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

    # Create an initial commit so we have a valid git_ref
    test_file = Path.join(tmp_dir, "test.txt")
    File.write!(test_file, "initial content")
    System.cmd("git", ["add", "test.txt"], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_dir)

    # Get the current commit SHA for use in tests
    {git_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    git_ref = String.trim(git_ref)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, working_dir: tmp_dir, git_ref: git_ref}
  end

  describe "create/4" do
    test "creates a new session from a checkpoint", %{working_dir: working_dir, git_ref: git_ref} do
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
      checkpoint = Checkpoint.new("test-checkpoint", 2, git_ref)
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

    test "preserves config from original session", %{working_dir: working_dir, git_ref: git_ref} do
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
      checkpoint = Checkpoint.new("config-checkpoint", 0, git_ref)
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

    test "creates git branch from checkpoint's git_ref", %{
      working_dir: working_dir,
      git_ref: git_ref
    } do
      # Create a source session
      source_session_id = "sess_git_test"
      config = %{model: "claude-sonnet-4-20250514"}

      session_start =
        SessionStart.new(source_session_id, working_dir, "claude-sonnet-4-20250514", config)

      Store.append(source_session_id, session_start, working_dir)

      # Create a checkpoint with the git ref
      checkpoint = Checkpoint.new("git-checkpoint", 0, git_ref)
      Store.append(source_session_id, checkpoint, working_dir)

      # Branch from the checkpoint
      new_session_id = "sess_abc123def456"

      assert {:ok, ^new_session_id} =
               Branch.create(source_session_id, "git-checkpoint", new_session_id, working_dir)

      # Verify that a git branch was created with the expected name
      # Expected branch name: deft/branch-abc123def456 (session_id without "sess_" prefix)
      expected_branch = "deft/branch-abc123def456"

      # Check that the branch exists
      {output, 0} = System.cmd("git", ["branch", "--list", expected_branch], cd: working_dir)
      assert String.contains?(output, expected_branch)

      # Verify the branch points to the correct commit
      {branch_ref, 0} =
        System.cmd("git", ["rev-parse", expected_branch], cd: working_dir, stderr_to_stdout: true)

      assert String.trim(branch_ref) == git_ref
    end

    test "filters OM snapshot to branch point", %{working_dir: working_dir, git_ref: git_ref} do
      # Create a source session
      source_session_id = "sess_om_test"
      config = %{model: "claude-sonnet-4-20250514"}

      session_start =
        SessionStart.new(source_session_id, working_dir, "claude-sonnet-4-20250514", config)

      Store.append(source_session_id, session_start, working_dir)

      # Add messages
      msg1 = %Message{
        type: :message,
        message_id: "msg_before_1",
        role: :user,
        content: [%{type: "text", text: "First"}],
        timestamp: DateTime.utc_now()
      }

      msg2 = %Message{
        type: :message,
        message_id: "msg_before_2",
        role: :assistant,
        content: [%{type: "text", text: "Second"}],
        timestamp: DateTime.utc_now()
      }

      Store.append(source_session_id, msg1, working_dir)
      Store.append(source_session_id, msg2, working_dir)

      # Create a checkpoint after the first two messages (entry_index 2)
      checkpoint = Checkpoint.new("om-checkpoint", 2, git_ref)
      Store.append(source_session_id, checkpoint, working_dir)

      # Add another message after the checkpoint
      msg3 = %Message{
        type: :message,
        message_id: "msg_after_1",
        role: :user,
        content: [%{type: "text", text: "After checkpoint"}],
        timestamp: DateTime.utc_now()
      }

      Store.append(source_session_id, msg3, working_dir)

      # Create an OM snapshot with all three message IDs observed
      alias Deft.Session.Entry.Observation
      alias Deft.OM.State, as: OMState
      alias Deft.Project

      om_snapshot = %Observation{
        type: :observation,
        active_observations: "Some observations",
        observation_tokens: 100,
        observed_message_ids: ["msg_before_1", "msg_before_2", "msg_after_1"],
        pending_message_tokens: 0,
        generation_count: 1,
        last_observed_at: DateTime.utc_now(),
        activation_epoch: 0,
        calibration_factor: 4.0,
        timestamp: DateTime.utc_now()
      }

      # Write the OM snapshot to the source session using the correct path
      sessions_dir = Project.sessions_dir(working_dir)
      om_path = Path.join(sessions_dir, "#{source_session_id}_om.jsonl")

      File.mkdir_p!(Path.dirname(om_path))
      {:ok, json} = Jason.encode(om_snapshot)
      File.write!(om_path, json <> "\n")

      # Verify source OM file was created and can be loaded
      assert File.exists?(om_path), "Source OM file should exist"

      {:ok, loaded_snapshot} = OMState.load_latest_snapshot(source_session_id, working_dir)
      assert loaded_snapshot != nil, "Should be able to load source OM snapshot"
      assert length(loaded_snapshot.observed_message_ids) == 3

      # Branch from the checkpoint
      new_session_id = "sess_om_branch"

      assert {:ok, ^new_session_id} =
               Branch.create(source_session_id, "om-checkpoint", new_session_id, working_dir)

      # Check if OM file exists for branched session
      branch_om_path = Path.join(sessions_dir, "#{new_session_id}_om.jsonl")

      assert File.exists?(branch_om_path),
             "OM file should exist at #{branch_om_path}"

      # Load the branched session's OM snapshot
      {:ok, branch_om_snapshot} = OMState.load_latest_snapshot(new_session_id, working_dir)

      # Verify that only messages before the checkpoint are in observed_message_ids
      assert branch_om_snapshot != nil,
             "OM snapshot should not be nil"

      assert "msg_before_1" in branch_om_snapshot.observed_message_ids
      assert "msg_before_2" in branch_om_snapshot.observed_message_ids
      refute "msg_after_1" in branch_om_snapshot.observed_message_ids

      # Verify that other fields are preserved
      assert branch_om_snapshot.active_observations == "Some observations"
      assert branch_om_snapshot.observation_tokens == 100
    end
  end
end
