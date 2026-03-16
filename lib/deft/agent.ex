defmodule Deft.Agent do
  @moduledoc """
  Agent loop for Deft — a gen_statem that manages the conversation flow.

  The agent receives prompts, calls the LLM provider, executes tools, and loops.
  It uses `handle_event` callback mode to support fallback handlers in any state
  (critical for abort functionality).

  ## States

  - `:idle` — Waiting for user input
  - `:calling` — Sending request to LLM provider, waiting for first stream event
  - `:streaming` — Receiving streaming response, accumulating text and tool calls
  - `:executing_tools` — Running tool calls, collecting results

  ## State Data

  The state data is a map containing:

  - `messages` — List of conversation messages (canonical `Deft.Message` format)
  - `config` — Configuration map for the agent
  - `session_id` — Unique identifier for the session
  - `current_message` — Message being accumulated during streaming (optional)
  - `stream_ref` — Reference to the current stream (optional)
  - `tool_tasks` — List of in-flight tool execution tasks (optional)
  - `prompt_queue` — Queue of prompts received while not idle (optional)
  - `turn_count` — Counter for consecutive LLM calls (optional)
  - `total_input_tokens` — Cumulative input tokens (optional)
  - `total_output_tokens` — Cumulative output tokens (optional)
  - `session_cost` — Cumulative estimated cost (optional)
  """

  @behaviour :gen_statem

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Agent.Context

  # Client API

  @doc """
  Starts the Agent gen_statem.

  ## Options

  - `:session_id` — Required. Unique identifier for the session.
  - `:config` — Required. Configuration map for the agent.
  - `:messages` — Optional. Initial conversation messages (default: []).
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    initial_messages = Keyword.get(opts, :messages, [])

    initial_data = %{
      session_id: session_id,
      config: config,
      messages: initial_messages,
      current_message: nil,
      stream_ref: nil,
      tool_tasks: [],
      prompt_queue: :queue.new(),
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      session_cost: 0.0
    }

    :gen_statem.start_link(__MODULE__, initial_data, [])
  end

  @doc """
  Sends a prompt to the agent.

  If the agent is not idle, the prompt is queued and delivered when idle.
  """
  def prompt(agent, text) do
    :gen_statem.cast(agent, {:prompt, text})
  end

  @doc """
  Aborts the current operation and returns to idle state.

  Cancels any in-flight stream or tool executions.
  """
  def abort(agent) do
    :gen_statem.cast(agent, :abort)
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    :handle_event_function
  end

  @impl :gen_statem
  def init(initial_data) do
    {:ok, :idle, initial_data}
  end

  @impl :gen_statem
  def handle_event(:cast, {:prompt, text}, :idle, data) do
    # Create user message
    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }

    # Append to conversation history
    new_messages = data.messages ++ [user_message]

    # Assemble context
    context_messages = Context.build(new_messages, config: data.config)

    # Get provider from config (default to nil for now)
    provider = Map.get(data.config, :provider)

    # Get tools (empty for now, will be populated by future work items)
    tools = []

    # Call provider.stream/3
    case call_provider_stream(provider, context_messages, tools, data.config) do
      {:ok, stream_ref} ->
        # Store stream ref and updated messages, transition to :calling
        new_data = %{
          data
          | messages: new_messages,
            stream_ref: stream_ref
        }

        {:next_state, :calling, new_data}

      {:error, reason} ->
        # On error, stay in :idle and emit error event
        # Error recovery with retries will be implemented in :calling → :streaming transition
        broadcast_event(data.session_id, {:error, reason})
        :keep_state_and_data
    end
  end

  def handle_event(:cast, {:prompt, text}, _state, data) do
    # Queue prompt if not idle
    new_queue = :queue.in(text, data.prompt_queue)
    new_data = %{data | prompt_queue: new_queue}
    {:keep_state, new_data}
  end

  def handle_event(:cast, :abort, _state, data) do
    # Placeholder: abort logic will be implemented in future work item
    # For now, just transition to idle
    {:next_state, :idle, data}
  end

  def handle_event(:info, {:provider_event, _event}, :calling, _data) do
    # Placeholder: transition to :streaming will be implemented in future work item
    :keep_state_and_data
  end

  def handle_event(:info, {:provider_event, _event}, :streaming, _data) do
    # Placeholder: streaming logic will be implemented in future work item
    :keep_state_and_data
  end

  def handle_event(_event_type, _event_content, _state, _data) do
    # Catch-all for unhandled events
    :keep_state_and_data
  end

  @impl :gen_statem
  def terminate(_reason, _state, _data) do
    :ok
  end

  # Private helpers

  defp generate_message_id do
    # Generate a unique message ID using UUID
    "msg_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp call_provider_stream(nil, _messages, _tools, _config) do
    # No provider configured
    {:error, :no_provider}
  end

  defp call_provider_stream(provider, messages, tools, config) do
    # Call provider.stream/3
    provider.stream(messages, tools, config)
  end

  defp broadcast_event(session_id, event) do
    # Broadcast event via Registry for TUI and other consumers
    # Registry key is {:session, session_id}
    Registry.dispatch(Deft.Registry, {:session, session_id}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:agent_event, event})
      end
    end)
  end
end
