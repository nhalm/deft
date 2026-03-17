defmodule Deft.OM.StateTest do
  use ExUnit.Case, async: true

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.OM.{BufferedChunk, State}

  setup do
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"

    config = %Config{
      model: "claude-sonnet-4.5",
      provider: "anthropic",
      turn_limit: 100,
      tool_timeout: 120_000,
      bash_timeout: 120_000,
      om_enabled: true,
      om_observer_model: "claude-haiku-4.5",
      om_reflector_model: "claude-haiku-4.5",
      cache_token_threshold: 10_000,
      cache_token_threshold_read: 20_000,
      cache_token_threshold_grep: 8_000,
      cache_token_threshold_ls: 4_000,
      cache_token_threshold_find: 4_000
    }

    # Start OM.Supervisor which will start State
    {:ok, _pid} =
      start_supervised({Deft.OM.Supervisor, session_id: session_id, config: config})

    {:ok, session_id: session_id, config: config}
  end

  describe "observation activation" do
    test "activates buffered chunks when pending tokens >= threshold", %{session_id: session_id} do
      # Create some buffered chunks manually
      chunk1 = %BufferedChunk{
        observations:
          "## Current State\n- (10:00) Task: Reading files\n\n## Session History\n- (10:00) User asked about auth",
        token_count: 100,
        message_ids: ["msg1", "msg2"],
        message_tokens: 1500,
        epoch: 0
      }

      chunk2 = %BufferedChunk{
        observations:
          "## Current State\n- (10:05) Task: Writing code\n\n## Session History\n- (10:05) Implemented JWT verification",
        token_count: 120,
        message_ids: ["msg3", "msg4"],
        message_tokens: 1500,
        epoch: 0
      }

      # Inject buffered chunks into state (using GenServer internals for testing)
      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [chunk1, chunk2],
            pending_message_tokens: 30_000
        }
      end)

      # Add messages to trigger activation check
      messages = [
        %Message{
          id: "msg5",
          role: :user,
          content: [%Text{text: "continue"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)

      # Give it a moment to process
      Process.sleep(50)

      # Check that buffered chunks were activated
      {observations, observed_ids} = State.get_context(session_id)

      # Should have merged observations
      assert observations != ""
      assert String.contains?(observations, "Writing code")
      assert String.contains?(observations, "Implemented JWT verification")

      # Should have collected all message IDs
      assert "msg1" in observed_ids
      assert "msg2" in observed_ids
      assert "msg3" in observed_ids
      assert "msg4" in observed_ids

      # Should have activated (check via sys:get_state)
      state = :sys.get_state(via_tuple(session_id))
      # After activation, buffered_chunks were cleared and epoch incremented
      # Note: There may be new chunks from the trigger message, so we check epoch instead
      assert state.activation_epoch >= 1
      assert state.snapshot_dirty == true
      assert state.last_observed_at != nil
      # Observation tokens should be non-zero (we merged chunks)
      assert state.observation_tokens > 0
    end

    test "section-aware merge replaces Current State", %{session_id: session_id} do
      chunk1 = %BufferedChunk{
        observations: "## Current State\n- (10:00) Task: Old task",
        token_count: 50,
        message_ids: ["msg1"],
        message_tokens: 1500,
        epoch: 0
      }

      chunk2 = %BufferedChunk{
        observations: "## Current State\n- (10:05) Task: New task",
        token_count: 50,
        message_ids: ["msg2"],
        message_tokens: 1500,
        epoch: 0
      }

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [chunk1, chunk2],
            pending_message_tokens: 30_000
        }
      end)

      messages = [
        %Message{
          id: "trigger",
          role: :user,
          content: [%Text{text: "go"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)
      Process.sleep(50)

      {observations, _} = State.get_context(session_id)

      # Current State should be replaced, not appended
      assert String.contains?(observations, "New task")
      refute String.contains?(observations, "Old task")
    end

    test "section-aware merge appends to Session History", %{session_id: session_id} do
      chunk1 = %BufferedChunk{
        observations: "## Session History\n- (10:00) First event",
        token_count: 50,
        message_ids: ["msg1"],
        message_tokens: 1500,
        epoch: 0
      }

      chunk2 = %BufferedChunk{
        observations: "## Session History\n- (10:05) Second event",
        token_count: 50,
        message_ids: ["msg2"],
        message_tokens: 1500,
        epoch: 0
      }

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [chunk1, chunk2],
            pending_message_tokens: 30_000
        }
      end)

      messages = [
        %Message{
          id: "trigger",
          role: :user,
          content: [%Text{text: "go"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)
      Process.sleep(50)

      {observations, _} = State.get_context(session_id)

      # Session History should have both events
      assert String.contains?(observations, "First event")
      assert String.contains?(observations, "Second event")
    end

    test "does not activate if pending tokens below threshold", %{session_id: session_id} do
      chunk = %BufferedChunk{
        observations: "## Current State\n- Task",
        token_count: 50,
        message_ids: ["msg1"],
        message_tokens: 100,
        epoch: 0
      }

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [chunk],
            pending_message_tokens: 1000
        }
      end)

      messages = [
        %Message{
          id: "trigger",
          role: :user,
          content: [%Text{text: "go"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)
      Process.sleep(50)

      # Should NOT have activated
      state = :sys.get_state(via_tuple(session_id))
      assert length(state.buffered_chunks) == 1
      assert state.activation_epoch == 0
    end

    test "does not activate if buffered_chunks empty", %{session_id: session_id} do
      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [],
            pending_message_tokens: 30_000
        }
      end)

      messages = [
        %Message{
          id: "trigger",
          role: :user,
          content: [%Text{text: "go"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)
      Process.sleep(50)

      # Should NOT have activated (epoch stays 0)
      state = :sys.get_state(via_tuple(session_id))
      assert state.activation_epoch == 0
    end

    test "subtracts observed tokens from pending", %{session_id: session_id} do
      chunk = %BufferedChunk{
        observations: "## Current State\n- Task",
        token_count: 50,
        message_ids: ["msg1"],
        message_tokens: 5000,
        epoch: 0
      }

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | buffered_chunks: [chunk],
            pending_message_tokens: 32_000
        }
      end)

      messages = [
        %Message{
          id: "trigger",
          role: :user,
          content: [%Text{text: "go"}],
          timestamp: DateTime.utc_now()
        }
      ]

      State.messages_added(session_id, messages)
      Process.sleep(50)

      state = :sys.get_state(via_tuple(session_id))

      # pending should be reduced by the chunk's message_tokens (5000)
      # Original: 32000, subtract 5000 = 27000, plus small amount from "go" message
      assert state.pending_message_tokens < 30_000
      assert state.pending_message_tokens > 25_000
    end
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}}
  end
end
