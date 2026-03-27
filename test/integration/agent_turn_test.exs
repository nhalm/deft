defmodule Integration.AgentTurnTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Deft.Agent
  alias Deft.ScriptedProvider
  alias Deft.Message.{Text, ToolUse, ToolResult}

  setup_all do
    # Ensure Registry is running
    case Process.whereis(Deft.Registry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :duplicate, name: Deft.Registry)

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

  describe "single-agent turn loop" do
    test "simple text response without tools", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Start with a simple response without tool calls
      # Add a small delay to give us time to see state transitions
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              text: "Hello, I understand.",
              tool_calls: [],
              usage: %{input: 50, output: 20},
              delay_ms: 100
            }
          ]
        )

      # Start agent
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            working_dir: temp_dir,
            tool_supervisor: tool_supervisor,
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to events BEFORE prompting
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Hello")

      # Check for calling state change
      assert_receive {:agent_event, {:state_change, :calling}}, 1000

      # Check for streaming state change
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000

      # Wait for completion
      Process.sleep(200)

      # Verify final state
      {current_state, data} = :sys.get_state(agent)
      assert current_state == :idle

      # Verify messages
      assert length(data.messages) == 2
      [user_msg, assistant_msg] = data.messages
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end

    test "completes full state machine cycle: tool call → execution → text response", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Setup: Script two responses
      # 1. Assistant responds with a tool call to bash
      # 2. After tool execution, assistant responds with text
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            # First response: tool call (no text - matches real LLM behavior)
            %{
              tool_calls: [
                %{
                  name: "bash",
                  args: %{"command" => "echo 'Hello from test'"}
                }
              ],
              usage: %{input: 100, output: 50}
            },
            # Second response: text after tool execution
            %{
              text: "The command executed successfully.",
              tool_calls: [],
              usage: %{input: 150, output: 30}
            }
          ]
        )

      # Start agent with ScriptedProvider
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            working_dir: temp_dir,
            bash_timeout: 5000,
            tools: [Deft.Tools.Bash],
            tool_supervisor: tool_supervisor,
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Verify agent is in idle state
      {current_state, _} = :sys.get_state(agent)
      assert current_state == :idle

      # Send prompt to trigger the turn loop
      Agent.prompt(agent, "What's in the current directory?")

      # Give agent a moment to process the prompt
      Process.sleep(10)

      # Collect state transitions and verify the full cycle
      # Expected: :calling → :streaming → :executing_tools → :calling → :streaming → :idle
      state_transitions =
        collect_state_transitions([], [
          :calling,
          :streaming,
          :executing_tools,
          :calling,
          :streaming
        ])

      # Verify state transitions occurred in the correct order
      assert state_transitions == [
               :calling,
               :streaming,
               :executing_tools,
               :calling,
               :streaming
             ]

      # Wait for agent to return to idle
      Process.sleep(100)
      {current_state, _data} = :sys.get_state(agent)
      assert current_state == :idle

      # Verify messages were accumulated correctly
      {_state, data} = :sys.get_state(agent)
      messages = data.messages

      # Should have 3 messages:
      # 1. User prompt
      # 2. Assistant with tool use
      # 3. User with tool result
      # 4. Assistant with final text
      assert length(messages) == 4

      # Verify user prompt
      [user_msg | rest] = messages
      assert user_msg.role == :user
      assert match?([%Text{text: "What's in the current directory?"}], user_msg.content)

      # Verify assistant tool call (no text, just tool use)
      [assistant_tool_msg | rest] = rest
      assert assistant_tool_msg.role == :assistant
      assert match?([%ToolUse{name: "bash"}], assistant_tool_msg.content)

      # Verify tool result
      [tool_result_msg | rest] = rest
      assert tool_result_msg.role == :user
      [tool_result] = tool_result_msg.content
      assert match?(%ToolResult{name: "bash", is_error: false}, tool_result)
      assert tool_result.content =~ "Hello from test"

      # Verify final assistant response
      [final_assistant_msg] = rest
      assert final_assistant_msg.role == :assistant

      assert match?(
               [%Text{text: "The command executed successfully."}],
               final_assistant_msg.content
             )

      # Verify all scripted responses were consumed
      ScriptedProvider.assert_exhausted(provider_pid)

      # Verify exactly 2 LLM calls were made
      ScriptedProvider.assert_called(provider_pid, 2)
    end

    test "broadcasts events via Registry during state transitions", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Setup: Script a simple tool call response
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              tool_calls: [
                %{
                  name: "bash",
                  args: %{"command" => "echo test"}
                }
              ]
            },
            %{
              text: "Done.",
              tool_calls: []
            }
          ]
        )

      # Start agent
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            working_dir: temp_dir,
            bash_timeout: 5000,
            tools: [Deft.Tools.Bash],
            tool_supervisor: tool_supervisor,
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Run a command")

      # Verify state_change events are broadcast
      assert_receive {:agent_event, {:state_change, :calling}}, 1000
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000

      # Should receive text deltas
      receive_text_deltas_until_tool_call()

      # Should transition to executing_tools (but this happens via enter handler, not explicit broadcast)
      # So we just verify we get tool execution events

      # Wait for tool execution to complete and next turn
      assert_receive {:agent_event, {:state_change, :calling}}, 2000
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000

      # Receive final text deltas
      receive_text_deltas_until_done()

      # Verify agent is back in idle
      Process.sleep(50)
      {current_state, _data} = :sys.get_state(agent)
      assert current_state == :idle
    end
  end

  # Helper to collect state transitions until all expected states are seen
  defp collect_state_transitions(acc, []) do
    Enum.reverse(acc)
  end

  defp collect_state_transitions(acc, [expected_state | remaining_states]) do
    receive do
      {:agent_event, {:state_change, ^expected_state}} ->
        collect_state_transitions([expected_state | acc], remaining_states)

      {:agent_event, _other} ->
        # Ignore other events (text deltas, etc.)
        collect_state_transitions(acc, [expected_state | remaining_states])
    after
      5000 ->
        flunk(
          "Timeout waiting for state transition to #{expected_state}. Got: #{inspect(Enum.reverse(acc))}"
        )
    end
  end

  # Helper to consume text delta events until we see a tool call or done
  defp receive_text_deltas_until_tool_call do
    receive do
      {:agent_event, {:text_delta, _}} ->
        receive_text_deltas_until_tool_call()

      {:agent_event, {:thinking_delta, _}} ->
        receive_text_deltas_until_tool_call()

      {:agent_event, {:tool_call_start, _}} ->
        # Consume remaining tool call events
        receive_tool_call_events()

      {:agent_event, _} ->
        receive_text_deltas_until_tool_call()
    after
      2000 ->
        :ok
    end
  end

  defp receive_tool_call_events do
    receive do
      {:agent_event, {:tool_call_delta, _}} ->
        receive_tool_call_events()

      {:agent_event, {:tool_call_done, _}} ->
        :ok

      {:agent_event, _} ->
        receive_tool_call_events()
    after
      1000 ->
        :ok
    end
  end

  defp receive_text_deltas_until_done do
    receive do
      {:agent_event, {:text_delta, _}} ->
        receive_text_deltas_until_done()

      {:agent_event, {:thinking_delta, _}} ->
        receive_text_deltas_until_done()

      {:agent_event, _} ->
        :ok
    after
      1000 ->
        :ok
    end
  end
end
