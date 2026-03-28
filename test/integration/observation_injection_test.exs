defmodule Integration.ObservationInjectionTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Deft.Agent
  alias Deft.ScriptedProvider
  alias Deft.Message.Text
  alias Deft.OM.Supervisor, as: OMSupervisor
  alias Deft.OM.State, as: OMState
  alias Deft.Provider.Event.{TextDelta, Usage, Done}

  # Simple test provider for Observer calls
  defmodule TestObserverProvider do
    @behaviour Deft.Provider

    @impl true
    def stream(_messages, _tools, _config) do
      caller = self()

      stream_pid =
        spawn(fn ->
          # Emit observation response in XML format (required by Observer.Parse)
          # Use known section names: Current State, User Preferences, Files & Architecture, Decisions, Session History
          observation_text = """
          <observations>
          ## Current State

          User is asking for help with multiple tasks.

          ## Decisions

          - 2026-03-28: User requested help with task processing
          - User mentioned finding information
          </observations>

          <current-task>
          Helping user with task processing
          </current-task>

          <continuation-hint>
          Continue helping with the tasks we discussed earlier.
          </continuation-hint>
          """

          send(caller, {:provider_event, %TextDelta{delta: observation_text}})

          # Emit usage
          send(caller, {:provider_event, %Usage{input: 200, output: 80}})

          # Emit done
          send(caller, {:provider_event, %Done{}})
        end)

      {:ok, stream_pid}
    end

    @impl true
    def cancel_stream(stream_ref) when is_pid(stream_ref) do
      Process.exit(stream_ref, :cancelled)
      :ok
    end

    @impl true
    def parse_event(_sse_event), do: :skip

    @impl true
    def format_messages(messages), do: messages

    @impl true
    def format_tools(tools), do: tools

    @impl true
    def model_config(_model_name) do
      %{
        context_window: 200_000,
        max_output: 8192,
        input_price_per_mtok: 0.0,
        output_price_per_mtok: 0.0
      }
    end
  end

  setup_all do
    # Ensure Registry is running
    case Process.whereis(Deft.Registry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :duplicate, name: Deft.Registry)

      _pid ->
        :ok
    end

    # Ensure ProcessRegistry is running (for OM processes)
    case Process.whereis(Deft.ProcessRegistry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :unique, name: Deft.ProcessRegistry)

      _pid ->
        :ok
    end

    # Ensure Provider.Registry is running
    case Process.whereis(Deft.Provider.Registry) do
      nil ->
        {:ok, _} = Deft.Provider.Registry.start_link()

      _pid ->
        :ok
    end

    :ok
  end

  setup do
    # Create unique session ID for each test
    session_id = "test_session_#{:erlang.unique_integer([:positive])}"

    # Create temp directory for this test session
    temp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(temp_dir)

    # Start a Task.Supervisor for tool execution and register it under the expected via_tuple
    tool_runner_name = {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
    {:ok, tool_supervisor} = Task.Supervisor.start_link(name: tool_runner_name)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, session_id: session_id, temp_dir: temp_dir, tool_supervisor: tool_supervisor}
  end

  describe "observation injection (scenario 2.6)" do
    test "observer fires and observations are injected into next LLM call", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Register test observer provider
      Deft.Provider.Registry.register("test-observer", TestObserverProvider)

      # Set very low thresholds to trigger observation quickly
      # With ~20 tokens per turn, we'll cross the 50 token threshold in 3 turns
      # buffer_interval is a fraction, so 0.4 * 50 = 20 token buffer_size
      om_config = %{
        enabled: true,
        observer_provider: "test-observer",
        observer_model: "test-model",
        reflector_provider: "test-observer",
        reflector_model: "test-model",
        message_token_threshold: 50,
        observation_token_threshold: 1000,
        buffer_interval: 0.4,
        buffer_tail_retention: 0.2,
        hard_threshold_multiplier: 1.5,
        previous_observer_tokens: 2000,
        observer_temperature: 0.0
      }

      config = %{
        provider: ScriptedProvider,
        working_dir: temp_dir,
        tool_supervisor: tool_supervisor,
        model: "test-model",
        om_enabled: true,
        om_observer_provider: "test-observer",
        om_observer_model: "test-model",
        om_reflector_provider: "test-observer",
        om_reflector_model: "test-model",
        om_message_token_threshold: om_config.message_token_threshold,
        om_observation_token_threshold: om_config.observation_token_threshold,
        om_buffer_interval: om_config.buffer_interval,
        om_buffer_tail_retention: om_config.buffer_tail_retention,
        om_hard_threshold_multiplier: om_config.hard_threshold_multiplier,
        om_previous_observer_tokens: om_config.previous_observer_tokens,
        om_observer_temperature: om_config.observer_temperature
      }

      # Start ScriptedProvider with responses for:
      # - 3 agent turns (to cross the observation threshold)
      # - 1 agent turn after observation (to verify injection)
      # Note: Observer calls use TestObserverProvider, not ScriptedProvider
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            # Turn 1: Simple response
            %{
              text: "I understand your first request. Let me help with that.",
              tool_calls: [],
              usage: %{input: 100, output: 100}
            },
            # Turn 2: Another response
            %{
              text: "I've processed that information. Here's what I found.",
              tool_calls: [],
              usage: %{input: 100, output: 100}
            },
            # Turn 3: Third response - this should cross the 500 token threshold
            %{
              text: "Got it. I'll continue working on this task for you.",
              tool_calls: [],
              usage: %{input: 100, output: 100}
            },
            # Turn 4: After observation - this turn should have observations injected
            %{
              text: "I have the context from our earlier conversation.",
              tool_calls: [],
              usage: %{input: 150, output: 50}
            }
          ]
        )

      config = Map.put(config, :provider_pid, provider_pid)

      # Start OM Supervisor for this session
      {:ok, _om_supervisor} =
        start_supervised(
          {OMSupervisor, session_id: session_id, config: config, messages: []},
          id: {:om_supervisor, session_id}
        )

      # Start agent
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: config,
          messages: []
        )

      # Subscribe to events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Initial state check - no observations yet
      {observations_0, observed_ids_0, hint_0, _cal, pending_0, obs_tokens_0} =
        OMState.get_context(session_id)

      assert observations_0 == ""
      assert observed_ids_0 == []
      assert hint_0 == nil
      assert pending_0 == 0
      assert obs_tokens_0 == 0

      # Turn 1
      Agent.prompt(agent, "Can you help me with this task?")
      wait_for_idle(agent)

      # Check OM state - should have some pending tokens but no observations yet
      {observations_1, observed_ids_1, _hint_1, _cal, pending_1, _obs_tokens_1} =
        OMState.get_context(session_id)

      assert observations_1 == ""
      assert observed_ids_1 == []
      assert pending_1 > 0, "Should have pending tokens after turn 1"

      # Turn 2
      Agent.prompt(agent, "And also process this information.")
      wait_for_idle(agent)

      # Check OM state - more pending tokens, still no observations
      {observations_2, observed_ids_2, _hint_2, _cal, pending_2, _obs_tokens_2} =
        OMState.get_context(session_id)

      assert observations_2 == ""
      assert observed_ids_2 == []
      assert pending_2 > pending_1, "Should have more pending tokens after turn 2"

      # Turn 3 - this should cross the threshold and trigger observation
      Agent.prompt(agent, "Continue with the task please.")
      wait_for_idle(agent)

      # Wait a bit for async observation to complete
      Process.sleep(1000)

      # Check OM state - should now have observations
      {observations_3, observed_ids_3, _hint_3, _cal, pending_3, obs_tokens_3} =
        OMState.get_context(session_id)

      # Verify observer fired and created observations
      assert observations_3 != "", "Observations should be extracted"
      assert observations_3 =~ "Current State", "Should contain Current State section"
      assert observations_3 =~ "Decisions", "Should contain Decisions section"
      assert observations_3 =~ "task processing", "Should contain observed facts"

      # Verify observed messages were marked
      assert length(observed_ids_3) > 0, "Should have observed message IDs"

      # Verify pending tokens were reduced (observed messages moved to observations)
      assert pending_3 < pending_2, "Pending tokens should be reduced after observation"

      # Verify observation tokens increased
      assert obs_tokens_3 > 0, "Observation tokens should be > 0"

      # Turn 4 - verify observations are injected into context
      Agent.prompt(agent, "What do you remember from earlier?")
      wait_for_idle(agent)

      # Get the calls made to ScriptedProvider
      calls = ScriptedProvider.calls(provider_pid)

      # The 4th call (index 3) should have observations injected
      # Calls: [turn1, turn2, turn3, turn4] (Observer calls go to TestObserverProvider)
      # We want to check turn4 (index 3)
      assert length(calls) >= 4, "Should have made at least 4 calls"
      {turn4_messages, _tools, _config} = Enum.at(calls, 3)

      # Verify observations were injected
      observation_message =
        Enum.find(turn4_messages, fn msg ->
          msg.id == "om_observations"
        end)

      assert observation_message != nil, "Should have observation message in context"
      [%Text{text: obs_text}] = observation_message.content
      assert obs_text =~ "Observations", "Should contain observations preamble"
      assert obs_text =~ "Current State", "Should contain extracted observations"

      # Verify observed messages were trimmed
      # Some of the early messages should be gone from the context
      message_ids_in_turn4 = Enum.map(turn4_messages, & &1.id)

      # At least one observed message should have been trimmed
      # (some may be kept in the tail based on buffer_tail_retention)
      trimmed_count =
        Enum.count(observed_ids_3, fn obs_id ->
          obs_id not in message_ids_in_turn4
        end)

      assert trimmed_count > 0, "At least some observed messages should be trimmed from context"

      # Verify continuation hint was injected (if messages were actually trimmed)
      if trimmed_count > 0 do
        continuation_hint_message =
          Enum.find(turn4_messages, fn msg ->
            msg.id == "om_continuation_hint" and msg.role == :user
          end)

        assert continuation_hint_message != nil,
               "Should have continuation hint when messages are trimmed"

        [%Text{text: hint_text}] = continuation_hint_message.content

        assert hint_text =~ "Continue helping",
               "Continuation hint should prompt natural continuation"
      end

      # Verify all scripted responses were consumed
      ScriptedProvider.assert_exhausted(provider_pid)
    end
  end

  # Helper to wait for agent to return to idle state
  defp wait_for_idle(agent, timeout \\ 5000) do
    start_time = :os.system_time(:millisecond)

    wait_for_idle_loop(agent, start_time, timeout)
  end

  defp wait_for_idle_loop(agent, start_time, timeout) do
    elapsed = :os.system_time(:millisecond) - start_time

    if elapsed >= timeout do
      raise "Timeout waiting for agent to reach idle state"
    end

    {current_state, _data} = :sys.get_state(agent)

    if current_state == :idle do
      :ok
    else
      Process.sleep(50)
      wait_for_idle_loop(agent, start_time, timeout)
    end
  end
end
