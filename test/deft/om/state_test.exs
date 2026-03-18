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
      cache_token_threshold_find: 4_000,
      issues_compaction_days: 90
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
      {observations, observed_ids, _continuation_hint, _calibration_factor, _pending_tokens,
       _observation_tokens} = State.get_context(session_id)

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
      # After activation, snapshot is written and dirty flag is cleared
      assert state.snapshot_dirty == false
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

      {observations, _, _, _, _, _} = State.get_context(session_id)

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

      {observations, _, _, _, _, _} = State.get_context(session_id)

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

  describe "hard observation cap" do
    test "truncates Session History when observation_tokens > 60k", %{session_id: session_id} do
      # Build observations that exceed 60k tokens
      # Each line is roughly 50 characters = ~12 tokens at 4:1 ratio
      # Need ~5000 lines to reach 60k tokens
      session_history_lines =
        Enum.map(1..5500, fn i ->
          "- (10:#{rem(i, 60)}) 🟡 Event #{i}: User did something important here"
        end)
        |> Enum.join("\n")

      large_observations = """
      ## Current State
      - (10:00) Active task: Testing hard cap

      ## User Preferences
      - (10:00) 🔴 User prefers terse output

      ## Session History
      #{session_history_lines}
      """

      # Set state with observations > 60k tokens
      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | active_observations: large_observations,
            observation_tokens: 65_000,
            is_reflecting: false
        }
      end)

      # Manually trigger hard cap check by calling the private function via reflection simulation
      # In actual code, this would be triggered after reflection completes/fails
      # For testing, we'll use sys:replace_state to simulate calling maybe_apply_hard_cap
      state_before = :sys.get_state(via_tuple(session_id))
      assert state_before.observation_tokens == 65_000

      # Simulate reflection failure which would trigger hard cap
      # We'll send a DOWN message to trigger the reflector failure handler
      ref = make_ref()

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{state | reflector_ref: ref, is_reflecting: true}
      end)

      # Send DOWN message to trigger reflector failure path
      pid = GenServer.whereis(via_tuple(session_id))
      send(pid, {:DOWN, ref, :process, self(), :test_failure})

      # Give it a moment to process
      Process.sleep(100)

      # Check that hard cap was applied
      state_after = :sys.get_state(via_tuple(session_id))

      # Observations should be truncated
      assert state_after.observation_tokens < 60_000
      assert state_after.observation_tokens < state_before.observation_tokens

      # Current State and User Preferences should be preserved
      assert String.contains?(state_after.active_observations, "Testing hard cap")
      assert String.contains?(state_after.active_observations, "User prefers terse output")

      # Session History should be truncated (oldest entries removed)
      assert String.contains?(state_after.active_observations, "## Session History")

      # Should have fewer lines in Session History
      history_lines_after =
        state_after.active_observations
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "Event"))

      assert history_lines_after < 5500
    end

    test "preserves CORRECTION markers during hard cap truncation", %{session_id: session_id} do
      # Build observations with CORRECTION markers in Session History
      correction_lines = """
      - (10:01) 🟡 Event 1: Something happened
      - (10:02) 🔴 CORRECTION: Event 1 is incorrect — it actually happened differently
      """

      additional_lines =
        Enum.map(3..5500, fn i ->
          "- (10:#{rem(i, 60)}) 🟡 Event #{i}: More events"
        end)
        |> Enum.join("\n")

      session_history_with_corrections = correction_lines <> additional_lines

      large_observations = """
      ## Current State
      - (10:00) Active task: Testing correction preservation

      ## Session History
      #{session_history_with_corrections}
      """

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | active_observations: large_observations,
            observation_tokens: 65_000,
            is_reflecting: false
        }
      end)

      # Trigger hard cap via reflection failure
      ref = make_ref()

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{state | reflector_ref: ref, is_reflecting: true}
      end)

      pid = GenServer.whereis(via_tuple(session_id))
      send(pid, {:DOWN, ref, :process, self(), :test_failure})
      Process.sleep(100)

      state_after = :sys.get_state(via_tuple(session_id))

      # CORRECTION marker must be preserved even if its original context was truncated
      assert String.contains?(
               state_after.active_observations,
               "CORRECTION: Event 1 is incorrect"
             )
    end

    test "does not truncate when observation_tokens <= 60k", %{session_id: session_id} do
      # Set observations below threshold
      small_observations = """
      ## Current State
      - (10:00) Active task: Below threshold

      ## Session History
      - (10:01) 🟡 Event 1
      - (10:02) 🟡 Event 2
      """

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{
          state
          | active_observations: small_observations,
            observation_tokens: 50_000,
            is_reflecting: false
        }
      end)

      state_before = :sys.get_state(via_tuple(session_id))

      # Trigger reflection failure
      ref = make_ref()

      :sys.replace_state(via_tuple(session_id), fn state ->
        %{state | reflector_ref: ref, is_reflecting: true}
      end)

      pid = GenServer.whereis(via_tuple(session_id))
      send(pid, {:DOWN, ref, :process, self(), :test_failure})
      Process.sleep(100)

      state_after = :sys.get_state(via_tuple(session_id))

      # Should NOT have truncated (observations unchanged)
      assert state_after.observation_tokens == state_before.observation_tokens
      assert state_after.active_observations == state_before.active_observations
    end
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}}
  end
end
