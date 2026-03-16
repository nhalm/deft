defmodule Deft.AgentTest do
  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.Message
  alias Deft.Message.Text

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
    test "aborts and cleans up state" do
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
  end
end
