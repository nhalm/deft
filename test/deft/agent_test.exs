defmodule Deft.AgentTest do
  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.ScriptedProvider

  setup_all do
    # The Deft.Registry is started by the application, so we don't need to start it here
    # Just verify it's running
    case Process.whereis(Deft.Registry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :duplicate, name: Deft.Registry)

      _pid ->
        :ok
    end

    :ok
  end

  # Mock provider for testing
  defmodule MockProvider do
    @moduledoc """
    A mock provider that allows controlled testing of the Agent.
    """

    def stream(messages, _tools, config) do
      # Get the test process PID
      test_pid = Map.get(config, :test_pid)

      # Extract the last user message
      last_message =
        messages
        |> Enum.reverse()
        |> Enum.find(fn msg -> msg.role == :user end)

      prompt_text =
        case last_message do
          %Message{content: [%Text{text: text} | _]} -> text
          _ -> "unknown"
        end

      # Send prompt received event to test process
      if test_pid do
        send(test_pid, {:prompt_received, prompt_text})
      end

      # Create a stream reference but don't send events
      # This keeps the agent in :calling state for testing
      stream_ref = make_ref()

      {:ok, stream_ref}
    end

    def cancel_stream(_stream_ref) do
      :ok
    end
  end

  # Helper to start an agent with mock provider
  defp start_agent(opts \\ []) do
    test_pid = self()

    config =
      opts
      |> Keyword.get(:config, %{})
      |> Map.put(:provider, MockProvider)
      |> Map.put(:test_pid, test_pid)

    session_id = Keyword.get(opts, :session_id, "test_session_#{:rand.uniform(10000)}")
    messages = Keyword.get(opts, :messages, [])

    {:ok, agent} = Agent.start_link(session_id: session_id, config: config, messages: messages)

    {:ok, agent}
  end

  describe "prompt queueing" do
    test "queues prompts received while not idle" do
      {:ok, agent} = start_agent()

      # Send first prompt - agent transitions to :calling
      Agent.prompt(agent, "First prompt")

      # Wait for the agent to process the prompt and transition to :calling
      assert_receive {:prompt_received, "First prompt"}, 1000

      # Send second and third prompts while agent is in :calling state
      # These should be queued since agent is not :idle
      Agent.prompt(agent, "Second prompt")
      Agent.prompt(agent, "Third prompt")

      # Give the agent time to process the cast messages
      Process.sleep(10)

      # Check the agent's internal state to verify prompts are queued
      {state_name, state_data} = :sys.get_state(agent)

      # Agent should not be in :idle state
      assert state_name != :idle

      # The prompt queue should contain the second and third prompts
      # Queue structure is {reverse_queue, forward_queue}
      queue_list = :queue.to_list(state_data.prompt_queue)

      assert "Second prompt" in queue_list
      assert "Third prompt" in queue_list
      assert length(queue_list) == 2
    end

    test "prompt is processed immediately when agent is idle" do
      {:ok, agent} = start_agent()

      # Agent starts in :idle state
      {state_name, _} = :sys.get_state(agent)
      assert state_name == :idle

      # Send a prompt
      Agent.prompt(agent, "Hello")

      # Should be processed immediately, not queued
      assert_receive {:prompt_received, "Hello"}, 1000

      # Check that the prompt queue is still empty
      Process.sleep(10)
      {_state_name, state_data} = :sys.get_state(agent)

      queue_list = :queue.to_list(state_data.prompt_queue)
      # The first prompt should not be in the queue
      refute "Hello" in queue_list
    end
  end

  describe "abort/1" do
    test "aborts from :calling state and cleans up state" do
      {:ok, agent} = start_agent()

      # Start a prompt
      Agent.prompt(agent, "Task")

      # Wait for transition to :calling
      assert_receive {:prompt_received, "Task"}, 1000

      # Abort the operation
      Agent.abort(agent)

      # Give the agent time to process the abort
      Process.sleep(10)

      # Agent should be back in :idle state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle
      assert state_data.stream_ref == nil
      assert state_data.current_message == nil
    end

    test "aborts from :streaming state and cleans up state" do
      session_id = "test_session_#{:erlang.unique_integer([:positive])}"

      # Create a custom slow-streaming provider
      defmodule SlowStreamProvider do
        @behaviour Deft.Provider

        def stream(_messages, _tools, config) do
          caller = self()
          test_pid = Map.get(config, :test_pid)

          stream_pid =
            spawn(fn ->
              # Send first event to transition to :streaming
              alias Deft.Provider.Event.{TextDelta, Usage, Done}
              send(caller, {:provider_event, %TextDelta{delta: "Starting"}})

              # Notify test that streaming has started
              if test_pid, do: send(test_pid, :streaming_started)

              # Sleep to keep streaming for long enough to abort
              Process.sleep(5000)

              # These won't execute if aborted
              send(caller, {:provider_event, %TextDelta{delta: " more text"}})
              send(caller, {:provider_event, %Usage{input: 100, output: 50}})
              send(caller, {:provider_event, %Done{}})
            end)

          {:ok, stream_pid}
        end

        def cancel_stream(stream_ref) when is_pid(stream_ref) do
          Process.exit(stream_ref, :cancelled)
          :ok
        end

        def parse_event(_), do: :skip
        def format_messages(messages), do: messages
        def format_tools(tools), do: tools

        def model_config(_) do
          %{
            context_window: 200_000,
            max_output: 8192,
            input_price_per_mtok: 0.0,
            output_price_per_mtok: 0.0
          }
        end
      end

      # Start agent with SlowStreamProvider
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: SlowStreamProvider,
            test_pid: self(),
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Hello")

      # Wait for streaming to actually start
      assert_receive :streaming_started, 1000

      # Also wait for the streaming state change event
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000

      # Now abort while definitely in streaming state
      Agent.abort(agent)

      # Wait for abort event from streaming state
      assert_receive {:agent_event, {:abort, :streaming}}, 1000

      # Give the agent time to process the abort
      Process.sleep(50)

      # Agent should be back in :idle state with clean state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle
      assert state_data.stream_ref == nil
      assert state_data.current_message == nil
      assert state_data.tool_call_buffers == %{}
    end

    test "aborts from :executing_tools state and cleans up state" do
      # Create unique session ID for each test
      session_id = "test_session_#{:erlang.unique_integer([:positive])}"

      # Create temp directory for this test session
      temp_dir = Path.join(System.tmp_dir!(), session_id)
      File.mkdir_p!(temp_dir)

      # Start a Task.Supervisor for tool execution
      tool_runner_name = {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
      {:ok, _tool_supervisor} = Task.Supervisor.start_link(name: tool_runner_name)

      # Setup: Script a response with a tool call that has a long delay
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              tool_calls: [
                %{
                  name: "bash",
                  args: %{"command" => "sleep 10"}
                }
              ],
              usage: %{input: 100, output: 50}
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
            bash_timeout: 30_000,
            tools: [Deft.Tools.Bash],
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Run a command")

      # Wait for transition to executing_tools
      assert_receive {:agent_event, {:state_change, :executing_tools}}, 1000

      # Give a moment for tool execution to actually start
      Process.sleep(100)

      # Abort while executing tools
      Agent.abort(agent)

      # Wait for abort event
      assert_receive {:agent_event, {:abort, :executing_tools}}, 1000

      # Give the agent time to process the abort and clean up
      Process.sleep(100)

      # Agent should be back in :idle state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle
      assert state_data.stream_ref == nil
      assert state_data.current_message == nil
      assert state_data.tool_tasks == []
      assert state_data.tool_call_buffers == %{}

      # Cleanup
      File.rm_rf!(temp_dir)
    end
  end

  describe "turn limit enforcement" do
    setup do
      # Create unique session ID for each test
      session_id = "test_session_#{:erlang.unique_integer([:positive])}"

      # Create temp directory for this test session
      temp_dir = Path.join(System.tmp_dir!(), session_id)
      File.mkdir_p!(temp_dir)

      # Start a Task.Supervisor for tool execution
      tool_runner_name = {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
      {:ok, tool_supervisor} = Task.Supervisor.start_link(name: tool_runner_name)

      on_exit(fn ->
        File.rm_rf!(temp_dir)
      end)

      {:ok, session_id: session_id, temp_dir: temp_dir, tool_supervisor: tool_supervisor}
    end

    test "pauses after max_turns and waits for user confirmation", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Setup: Script 4 tool call responses (2 turns worth, to exceed max_turns of 2)
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            # Turn 1: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 1'"}}],
              usage: %{input: 100, output: 50}
            },
            # Turn 2: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 2'"}}],
              usage: %{input: 100, output: 50}
            },
            # Turn 3: tool call (this should trigger the limit)
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 3'"}}],
              usage: %{input: 100, output: 50}
            }
          ]
        )

      # Start agent with low max_turns
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
            model: "test-model",
            max_turns: 2
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Run some commands")

      # Wait for the turn limit to be reached
      # The agent should process turns 1 and 2, then hit the limit after turn 2
      assert_receive {:agent_event, {:turn_limit_reached, turn_count, max_turns}}, 5000
      assert turn_count == 3
      assert max_turns == 2

      # Give the agent a moment to stabilize
      Process.sleep(50)

      # Verify agent is paused in :executing_tools state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :executing_tools
      assert state_data.turn_count == 3
    end

    test "continues execution when user accepts", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Setup: Script responses to trigger limit and then continue
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            # Turn 1: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 1'"}}],
              usage: %{input: 100, output: 50}
            },
            # Turn 2: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 2'"}}],
              usage: %{input: 100, output: 50}
            },
            # Turn 3: text response (after user continues)
            %{
              text: "Completed all commands.",
              tool_calls: [],
              usage: %{input: 100, output: 30}
            }
          ]
        )

      # Start agent with low max_turns
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
            model: "test-model",
            max_turns: 2
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Run some commands")

      # Wait for turn limit
      assert_receive {:agent_event, {:turn_limit_reached, 3, 2}}, 5000

      # User accepts to continue
      Agent.continue_turn(agent, true)

      # Wait for the agent to complete and return to idle
      Process.sleep(500)

      # Verify agent is back in idle state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle

      # Verify turn counter was reset (should be 1 after the final turn)
      assert state_data.turn_count == 1
    end

    test "transitions to idle when user declines", %{
      session_id: session_id,
      temp_dir: temp_dir,
      tool_supervisor: tool_supervisor
    } do
      # Setup: Script responses to trigger limit
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            # Turn 1: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 1'"}}],
              usage: %{input: 100, output: 50}
            },
            # Turn 2: tool call
            %{
              tool_calls: [%{name: "bash", args: %{"command" => "echo 'turn 2'"}}],
              usage: %{input: 100, output: 50}
            }
          ]
        )

      # Start agent with low max_turns
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
            model: "test-model",
            max_turns: 2
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Agent.prompt(agent, "Run some commands")

      # Wait for turn limit
      assert_receive {:agent_event, {:turn_limit_reached, 3, 2}}, 5000

      # User declines to continue
      Agent.continue_turn(agent, false)

      # Wait for decline event and transition
      assert_receive {:agent_event, {:turn_limit_declined}}, 1000

      # Give agent time to transition
      Process.sleep(50)

      # Verify agent is back in idle state
      {state_name, _state_data} = :sys.get_state(agent)
      assert state_name == :idle
    end
  end

  describe "error recovery" do
    # ErrorProvider - emits Error events during streaming to test retry logic
    defmodule ErrorProvider do
      use GenServer
      alias Deft.Provider.Event.{Error, TextDelta, Usage, Done}

      @behaviour Deft.Provider

      def start_link(error_count) do
        GenServer.start_link(__MODULE__, error_count)
      end

      @impl GenServer
      def init(error_count) do
        {:ok, %{errors_remaining: error_count}}
      end

      @impl GenServer
      def handle_call(:get_and_decrement, _from, %{errors_remaining: count} = state) do
        new_count = max(0, count - 1)
        {:reply, count, %{state | errors_remaining: new_count}}
      end

      @impl Deft.Provider
      def stream(_messages, _tools, config) do
        caller = self()
        counter_pid = Map.fetch!(config, :error_counter_pid)

        # Get current error count and decrement
        errors_remaining = GenServer.call(counter_pid, :get_and_decrement)

        # Spawn a process that will emit an Error event or success
        stream_pid =
          spawn(fn ->
            if errors_remaining > 0 do
              send(caller, {:provider_event, %Error{message: "Provider error"}})
              # Keep process alive until cancelled (agent will cancel on error)
              receive do
                :never -> :ok
              end
            else
              send(caller, {:provider_event, %TextDelta{delta: "Success!"}})
              send(caller, {:provider_event, %Usage{input: 100, output: 50}})
              send(caller, {:provider_event, %Done{}})
            end
          end)

        {:ok, stream_pid}
      end

      @impl Deft.Provider
      def cancel_stream(stream_ref) when is_pid(stream_ref) do
        Process.exit(stream_ref, :cancelled)
        :ok
      end

      @impl Deft.Provider
      def parse_event(_sse_event), do: :skip

      @impl Deft.Provider
      def format_messages(messages), do: messages

      @impl Deft.Provider
      def format_tools(tools), do: tools

      @impl Deft.Provider
      def model_config(_model_name) do
        %{
          context_window: 200_000,
          max_output: 8192,
          input_price_per_mtok: 0.0,
          output_price_per_mtok: 0.0
        }
      end
    end

    setup do
      # Create unique session ID for each test
      session_id = "test_session_#{:erlang.unique_integer([:positive])}"

      # Create temp directory for this test session
      temp_dir = Path.join(System.tmp_dir!(), session_id)
      File.mkdir_p!(temp_dir)

      on_exit(fn ->
        File.rm_rf!(temp_dir)
      end)

      {:ok, session_id: session_id, temp_dir: temp_dir}
    end

    test "retries with exponential backoff after provider error", %{
      session_id: session_id,
      temp_dir: temp_dir
    } do
      # Start error counter that will return 2 errors then succeed
      {:ok, counter_pid} = ErrorProvider.start_link(2)

      # Start agent with ErrorProvider
      {:ok, agent} =
        Deft.Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ErrorProvider,
            error_counter_pid: counter_pid,
            working_dir: temp_dir,
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Deft.Agent.prompt(agent, "Hello")

      # Wait for state change to calling
      assert_receive {:agent_event, {:state_change, :calling}}, 1000

      # Wait for first retry event (retry_count: 1, max_retries: 3, delay: 1000)
      assert_receive {:agent_event, {:retry, 1, 3, 1000}}, 2000

      # Wait for second retry event (retry_count: 2, max_retries: 3, delay: 2000)
      assert_receive {:agent_event, {:retry, 2, 3, 2000}}, 3000

      # Wait for the agent to succeed and transition to streaming
      assert_receive {:agent_event, {:state_change, :streaming}}, 3000

      # Give the agent time to complete
      Process.sleep(500)

      # Verify agent is back in idle state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle

      # Verify retry counters were reset
      assert state_data.retry_count == 0
      assert state_data.retry_delay == 1000
    end

    test "transitions to idle with error after exhausting retries", %{
      session_id: session_id,
      temp_dir: temp_dir
    } do
      # Start error counter that will return 4 errors (exceeds max_retries of 3)
      {:ok, counter_pid} = ErrorProvider.start_link(4)

      # Start agent with ErrorProvider
      {:ok, agent} =
        Deft.Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ErrorProvider,
            error_counter_pid: counter_pid,
            working_dir: temp_dir,
            model: "test-model"
          },
          messages: []
        )

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send prompt
      Deft.Agent.prompt(agent, "Hello")

      # Wait for state change to calling
      assert_receive {:agent_event, {:state_change, :calling}}, 1000

      # Wait for retry events
      assert_receive {:agent_event, {:retry, 1, 3, 1000}}, 2000
      assert_receive {:agent_event, {:retry, 2, 3, 2000}}, 3000
      assert_receive {:agent_event, {:retry, 3, 3, 4000}}, 5000

      # Wait for the error event after exhausting retries (4000ms delay + processing time)
      assert_receive {:agent_event, {:error, _reason}}, 5000

      # Give the agent time to transition
      Process.sleep(50)

      # Verify agent is back in idle state
      {state_name, state_data} = :sys.get_state(agent)
      assert state_name == :idle

      # Verify retry counters were reset
      assert state_data.retry_count == 0
      assert state_data.retry_delay == 1000
    end
  end

  describe "sub-agent mode event broadcasting" do
    test "broadcasts events via Registry when started with parent_pid" do
      # Create a temporary directory for test sessions
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      # Create a mock parent process PID
      parent_pid = self()
      session_id = "sub_agent_test_#{:rand.uniform(10000)}"

      # Start ScriptedProvider with a simple response
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              text: "Hello from sub-agent",
              usage: %{input: 10, output: 5}
            }
          ]
        )

      # Start agent in sub-agent mode with parent_pid
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            model: "test-model",
            working_dir: tmp_dir
          },
          parent_pid: parent_pid
        )

      on_exit(fn ->
        # Stop the agent before cleanup to avoid race conditions
        if Process.alive?(agent), do: GenServer.stop(agent, :normal)
        File.rm_rf(tmp_dir)
      end)

      # Subscribe to agent events using the same session_id
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send a prompt to trigger the agent loop
      Deft.Agent.prompt(agent, "Test prompt")

      # Verify that events are broadcast via Registry
      assert_receive {:agent_event, {:state_change, :calling}}, 1000
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000
      assert_receive {:agent_event, {:text_delta, _text}}, 1000
      assert_receive {:agent_event, {:state_change, :idle}}, 1000

      # Verify the agent has the parent_pid set in its state data
      {_state_name, state_data} = :sys.get_state(agent)
      assert state_data.parent_pid == parent_pid
    end
  end

  describe "rate limiter integration" do
    # Mock RateLimiter GenServer for testing
    defmodule MockRateLimiter do
      use GenServer

      def start_link(test_pid) do
        GenServer.start_link(__MODULE__, test_pid)
      end

      @impl true
      def init(test_pid) do
        {:ok, %{test_pid: test_pid}}
      end

      @impl true
      def handle_call({:request, provider, estimated_tokens, priority}, _from, state) do
        # Notify test process that request was called
        send(state.test_pid, {:rate_limiter_request, provider, estimated_tokens, priority})
        # Always approve the request
        {:reply, {:ok, estimated_tokens}, state}
      end

      @impl true
      def handle_cast({:reconcile, provider, estimated_tokens, actual_usage}, state) do
        # Notify test process that reconcile was called
        send(state.test_pid, {:rate_limiter_reconcile, provider, estimated_tokens, actual_usage})
        {:noreply, state}
      end
    end

    test "calls RateLimiter.request before provider stream and reconcile after usage" do
      # Create a temporary directory for test sessions
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      session_id = "rate_limiter_test_#{:rand.uniform(10000)}"

      # Start mock rate limiter
      {:ok, rate_limiter_pid} = MockRateLimiter.start_link(self())

      # Start ScriptedProvider with a simple response
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              text: "Response text",
              usage: %{input: 100, output: 50}
            }
          ]
        )

      # Start agent with rate_limiter option
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            model: "test-model",
            working_dir: tmp_dir
          },
          rate_limiter: rate_limiter_pid
        )

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent, :normal)
        if Process.alive?(rate_limiter_pid), do: GenServer.stop(rate_limiter_pid, :normal)
        File.rm_rf(tmp_dir)
      end)

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send a prompt to trigger the agent loop
      Deft.Agent.prompt(agent, "Test prompt")

      # Verify that RateLimiter.request was called before provider stream
      assert_receive {:rate_limiter_request, ScriptedProvider, estimated_tokens, 1}, 1000
      assert estimated_tokens > 0

      # Wait for the agent to complete the turn
      assert_receive {:agent_event, {:state_change, :idle}}, 2000

      # Verify that RateLimiter.reconcile was called with actual usage
      assert_receive {:rate_limiter_reconcile, ScriptedProvider, _estimated_tokens, actual_usage},
                     1000

      assert actual_usage.input == 100
      assert actual_usage.output == 50

      # Verify the agent has the rate_limiter set in its state data
      {_state_name, state_data} = :sys.get_state(agent)
      assert state_data.rate_limiter == rate_limiter_pid
    end

    test "standalone agent without rate_limiter operates normally" do
      # Create a temporary directory for test sessions
      tmp_dir = System.tmp_dir!() |> Path.join("deft-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      session_id = "standalone_test_#{:rand.uniform(10000)}"

      # Start ScriptedProvider with a simple response
      {:ok, provider_pid} =
        ScriptedProvider.start_link(
          responses: [
            %{
              text: "Response text",
              usage: %{input: 100, output: 50}
            }
          ]
        )

      # Start agent without rate_limiter option (standalone mode)
      {:ok, agent} =
        Agent.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: provider_pid,
            model: "test-model",
            working_dir: tmp_dir
          }
          # No rate_limiter option
        )

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent, :normal)
        File.rm_rf(tmp_dir)
      end)

      # Subscribe to agent events
      Registry.register(Deft.Registry, {:session, session_id}, [])

      # Send a prompt to trigger the agent loop
      Deft.Agent.prompt(agent, "Test prompt")

      # Verify agent completes normally without rate limiter
      assert_receive {:agent_event, {:state_change, :calling}}, 1000
      assert_receive {:agent_event, {:state_change, :streaming}}, 1000
      assert_receive {:agent_event, {:state_change, :idle}}, 2000

      # Verify the agent has nil rate_limiter in its state data
      {_state_name, state_data} = :sys.get_state(agent)
      assert state_data.rate_limiter == nil
    end
  end
end
