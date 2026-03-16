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
  - `tool_call_buffers` — Map of tool_id → JSON string for accumulating tool call args (optional)
  - `prompt_queue` — Queue of prompts received while not idle (optional)
  - `turn_count` — Counter for consecutive LLM calls (optional)
  - `total_input_tokens` — Cumulative input tokens (optional)
  - `total_output_tokens` — Cumulative output tokens (optional)
  - `session_cost` — Cumulative estimated cost (optional)
  - `retry_count` — Number of retries attempted for current request (optional)
  - `retry_delay` — Current exponential backoff delay in ms (optional)
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
      tool_call_buffers: %{},
      prompt_queue: :queue.new(),
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      session_cost: 0.0,
      retry_count: 0,
      retry_delay: 1000
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
        # Store stream ref and updated messages, reset retry state, transition to :calling
        new_data = %{
          data
          | messages: new_messages,
            stream_ref: stream_ref,
            retry_count: 0,
            retry_delay: 1000
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

  def handle_event(:info, {:provider_event, event}, :calling, data) do
    case event do
      # First content chunk - transition to streaming
      {event_type, _payload}
      when event_type in [:text_delta, :thinking_delta, :tool_call_start] ->
        # Initialize current assistant message
        current_message = %Message{
          id: generate_message_id(),
          role: :assistant,
          content: [],
          timestamp: DateTime.utc_now()
        }

        new_data = %{
          data
          | current_message: current_message,
            retry_count: 0,
            retry_delay: 1000
        }

        broadcast_event(data.session_id, {:state_change, :streaming})
        {:next_state, :streaming, new_data}

      # Error event - retry with exponential backoff
      {:error, error_payload} ->
        handle_calling_error(error_payload, data)

      # Other events (usage, etc.) - keep waiting for first content
      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:retry_stream}, :calling, data) do
    # Retry after exponential backoff delay
    context_messages = Context.build(data.messages, config: data.config)
    provider = Map.get(data.config, :provider)
    tools = []

    case call_provider_stream(provider, context_messages, tools, data.config) do
      {:ok, stream_ref} ->
        # Update stream ref, keep retry count
        new_data = %{data | stream_ref: stream_ref}
        {:keep_state, new_data}

      {:error, reason} ->
        handle_calling_error(%{message: inspect(reason)}, data)
    end
  end

  def handle_event(:info, {:provider_event, {:text_delta, payload}}, :streaming, data) do
    handle_text_delta(payload, data)
  end

  def handle_event(:info, {:provider_event, {:thinking_delta, payload}}, :streaming, data) do
    handle_thinking_delta(payload, data)
  end

  def handle_event(:info, {:provider_event, {:tool_call_start, payload}}, :streaming, data) do
    handle_tool_call_start(payload, data)
  end

  def handle_event(:info, {:provider_event, {:tool_call_delta, payload}}, :streaming, data) do
    handle_tool_call_delta(payload, data)
  end

  def handle_event(:info, {:provider_event, {:tool_call_done, payload}}, :streaming, data) do
    handle_tool_call_done(payload, data)
  end

  def handle_event(:info, {:provider_event, {:usage, payload}}, :streaming, data) do
    handle_usage(payload, data)
  end

  def handle_event(:info, {:provider_event, {:done, _}}, :streaming, data) do
    handle_stream_done(data)
  end

  def handle_event(:info, {:provider_event, {:error, payload}}, :streaming, data) do
    handle_stream_error(payload, data)
  end

  def handle_event(:info, {:provider_event, _event}, :streaming, _data) do
    # Unrecognized event - ignore
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

  defp handle_calling_error(error_payload, data) do
    max_retries = 3

    if data.retry_count < max_retries do
      # Schedule retry with exponential backoff
      retry_count = data.retry_count + 1
      delay = data.retry_delay

      # Send delayed message to self for retry
      Process.send_after(self(), {:retry_stream}, delay)

      new_data = %{
        data
        | retry_count: retry_count,
          retry_delay: delay * 2
      }

      broadcast_event(data.session_id, {:retry, retry_count, max_retries, delay})
      {:keep_state, new_data}
    else
      # Max retries exceeded - transition to idle with error
      error_message = Map.get(error_payload, :message, "Unknown error")

      broadcast_event(
        data.session_id,
        {:error, "Failed after #{max_retries} retries: #{error_message}"}
      )

      # Reset retry state and transition to idle
      new_data = %{
        data
        | stream_ref: nil,
          retry_count: 0,
          retry_delay: 1000
      }

      {:next_state, :idle, new_data}
    end
  end

  defp handle_text_delta(%{delta: delta}, data) do
    new_message = append_text_delta(data.current_message, delta)
    new_data = %{data | current_message: new_message}
    broadcast_event(data.session_id, {:text_delta, delta})
    {:keep_state, new_data}
  end

  defp handle_thinking_delta(%{delta: delta}, data) do
    new_message = append_thinking_delta(data.current_message, delta)
    new_data = %{data | current_message: new_message}
    broadcast_event(data.session_id, {:thinking_delta, delta})
    {:keep_state, new_data}
  end

  defp handle_tool_call_start(%{id: id, name: name}, data) do
    # Create a ToolUse block with empty args (will be updated on tool_call_done)
    tool_use = %Deft.Message.ToolUse{id: id, name: name, args: %{}}
    new_content = data.current_message.content ++ [tool_use]
    new_message = %{data.current_message | content: new_content}

    # Initialize buffer for this tool call's JSON args
    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    new_buffers = Map.put(tool_call_buffers, id, "")

    new_data = %{data | current_message: new_message, tool_call_buffers: new_buffers}
    broadcast_event(data.session_id, {:tool_call_start, %{id: id, name: name}})
    {:keep_state, new_data}
  end

  defp handle_tool_call_delta(%{id: id, delta: delta}, data) do
    # Accumulate JSON fragment
    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    current_buffer = Map.get(tool_call_buffers, id, "")
    new_buffers = Map.put(tool_call_buffers, id, current_buffer <> delta)

    new_data = %{data | tool_call_buffers: new_buffers}
    broadcast_event(data.session_id, {:tool_call_delta, %{id: id, delta: delta}})
    {:keep_state, new_data}
  end

  defp handle_tool_call_done(%{id: id, args: parsed_args}, data) do
    # Update the ToolUse block with the parsed args
    new_message = update_tool_call_args(data.current_message, id, parsed_args)

    # Clear the buffer for this tool call
    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    new_buffers = Map.delete(tool_call_buffers, id)

    new_data = %{data | current_message: new_message, tool_call_buffers: new_buffers}
    broadcast_event(data.session_id, {:tool_call_done, %{id: id, args: parsed_args}})
    {:keep_state, new_data}
  end

  defp handle_usage(%{input: input_tokens, output: output_tokens}, data) do
    # Update token tracking
    new_data = %{
      data
      | total_input_tokens: data.total_input_tokens + input_tokens,
        total_output_tokens: data.total_output_tokens + output_tokens
    }

    broadcast_event(data.session_id, {:usage, %{input: input_tokens, output: output_tokens}})
    {:keep_state, new_data}
  end

  defp handle_stream_done(data) do
    # Finalize the assistant message and transition to :executing_tools
    finalized_message = data.current_message
    new_messages = data.messages ++ [finalized_message]

    new_data = %{
      data
      | messages: new_messages,
        current_message: nil,
        stream_ref: nil,
        tool_call_buffers: %{}
    }

    broadcast_event(data.session_id, {:state_change, :executing_tools})
    {:next_state, :executing_tools, new_data}
  end

  defp handle_stream_error(error_payload, data) do
    # Handle error - transition to idle
    error_message = Map.get(error_payload, :message, "Unknown streaming error")
    broadcast_event(data.session_id, {:error, error_message})

    new_data = %{
      data
      | current_message: nil,
        stream_ref: nil,
        tool_call_buffers: %{}
    }

    {:next_state, :idle, new_data}
  end

  defp append_text_delta(message, delta) do
    case List.last(message.content) do
      %Text{text: existing_text} ->
        # Update the last Text block
        new_text = existing_text <> delta
        new_content = List.replace_at(message.content, -1, %Text{text: new_text})
        %{message | content: new_content}

      _ ->
        # No Text block at the end, create a new one
        new_content = message.content ++ [%Text{text: delta}]
        %{message | content: new_content}
    end
  end

  defp append_thinking_delta(message, delta) do
    alias Deft.Message.Thinking

    case List.last(message.content) do
      %Thinking{text: existing_text} ->
        # Update the last Thinking block
        new_text = existing_text <> delta
        new_content = List.replace_at(message.content, -1, %Thinking{text: new_text})
        %{message | content: new_content}

      _ ->
        # No Thinking block at the end, create a new one
        new_content = message.content ++ [%Thinking{text: delta}]
        %{message | content: new_content}
    end
  end

  defp update_tool_call_args(message, tool_id, parsed_args) do
    alias Deft.Message.ToolUse

    # Find the ToolUse block with matching ID and update its args
    new_content =
      Enum.map(message.content, fn
        %ToolUse{id: ^tool_id} = tool_use ->
          %{tool_use | args: parsed_args}

        other ->
          other
      end)

    %{message | content: new_content}
  end
end
