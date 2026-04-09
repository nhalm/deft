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
  - `parent_pid` — PID of orchestrator process that owns this agent (optional, nil for standalone sessions)
  - `rate_limiter` — PID of RateLimiter GenServer for orchestrated jobs (optional, nil for standalone sessions)
  - `current_message` — Message being accumulated during streaming (optional)
  - `stream_ref` — Reference to the current stream (optional)
  - `stream_monitor_ref` — Monitor reference for the stream process (optional)
  - `tool_tasks` — List of in-flight tool execution tasks (optional)
  - `tool_call_buffers` — Map of tool_id → JSON string for accumulating tool call args (optional)
  - `prompt_queue` — Queue of prompts received while not idle (optional)
  - `turn_count` — Counter for consecutive LLM calls (optional)
  - `total_input_tokens` — Cumulative input tokens (optional)
  - `total_output_tokens` — Cumulative output tokens (optional)
  - `current_context_tokens` — Estimated tokens in current message list (optional)
  - `context_window` — Model's context window size (optional)
  - `session_cost` — Cumulative estimated cost (optional)
  - `retry_count` — Number of retries attempted for current request (optional)
  - `retry_delay` — Current exponential backoff delay in ms (optional)
  - `compaction_task_ref` — Task reference for ongoing compaction summarization (optional)
  - `compaction_task_pid` — Task PID for ongoing compaction summarization (optional)
  - `pending_compaction_data` — Data to use when compaction completes (optional)
  """

  require Logger

  @behaviour :gen_statem

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Agent.Context
  alias Deft.Agent.ToolRunner
  alias Deft.Session.Worker
  alias Deft.Session.Entry
  alias Deft.Session.Entry.Compaction
  alias Deft.Session.Entry.Cost
  alias Deft.Session.Store
  alias Deft.OM.State, as: OMState

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
    ToolCallDone,
    Usage,
    Done,
    Error
  }

  # Client API

  @doc """
  Starts the Agent gen_statem.

  ## Options

  - `:session_id` — Required. Unique identifier for the session.
  - `:config` — Required. Configuration map for the agent.
  - `:messages` — Optional. Initial conversation messages (default: []).
  - `:session_cost` — Optional. Initial session cost from resumed session (default: 0.0).
  - `:parent_pid` — Optional. PID of orchestrator process that owns this agent (default: nil).
  - `:rate_limiter` — Optional. PID of RateLimiter GenServer for orchestrated jobs (default: nil).
  - `:name` — Optional. Name for the gen_statem process.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    initial_messages = Keyword.get(opts, :messages, [])
    initial_session_cost = Keyword.get(opts, :session_cost, 0.0)
    parent_pid = Keyword.get(opts, :parent_pid)
    rate_limiter = Keyword.get(opts, :rate_limiter)
    name = Keyword.get(opts, :name)

    # Get context window from provider model config
    context_window = get_context_window(config)

    initial_data = %{
      session_id: session_id,
      config: config,
      messages: initial_messages,
      current_message: nil,
      stream_ref: nil,
      stream_monitor_ref: nil,
      stream_start_time: nil,
      turn_start_time: nil,
      tool_tasks: [],
      tool_call_buffers: %{},
      prompt_queue: :queue.new(),
      turn_count: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      current_context_tokens: 0,
      context_window: context_window,
      session_cost: initial_session_cost,
      retry_count: 0,
      retry_delay: 1000,
      saved_message_ids: MapSet.new(),
      tool_execution_times: %{},
      compaction_task_ref: nil,
      compaction_task_pid: nil,
      pending_compaction_data: nil,
      parent_pid: parent_pid,
      rate_limiter: rate_limiter
    }

    if name do
      :gen_statem.start_link(name, __MODULE__, initial_data, [])
    else
      :gen_statem.start_link(__MODULE__, initial_data, [])
    end
  end

  @doc """
  Sends a prompt to the agent.

  If the agent is not idle, the prompt is queued and delivered when idle.
  """
  def prompt(agent, text) do
    :gen_statem.cast(agent, {:prompt, text})
  end

  @doc """
  Injects a skill definition as a system-level instruction.

  Per spec section 2.4, skills must be injected as system instructions, not user messages.
  This function is used when a user invokes a skill via slash command (e.g., /review).

  If the agent is not idle, the skill injection is queued and delivered when idle.

  ## Parameters
  - `agent`: The agent PID or via tuple
  - `definition`: The skill definition text to inject as a system message
  - `args`: Optional arguments to send as a user message after the skill (default: nil)
  """
  def inject_skill(agent, definition, args \\ nil) do
    :gen_statem.cast(agent, {:inject_skill, definition, args})
  end

  @doc """
  Aborts the current operation and returns to idle state.

  Cancels any in-flight stream or tool executions.
  """
  def abort(agent) do
    :gen_statem.cast(agent, :abort)
  end

  @doc """
  Responds to a turn limit prompt.

  When the turn limit is reached, the agent pauses and asks if it should continue.
  Call this function with `true` to continue or `false` to stop.
  """
  def continue_turn(agent, should_continue) when is_boolean(should_continue) do
    :gen_statem.cast(agent, {:continue_turn, should_continue})
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init(initial_data) do
    {:ok, :idle, initial_data}
  end

  @impl :gen_statem
  # State entry handlers
  def handle_event(:enter, _old_state, :executing_tools, data) do
    # Extract tool calls from the last assistant message
    tool_calls = extract_tool_calls(data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls - defer transition via zero timeout (enter handlers can't use next_event)
      {:keep_state_and_data, [{:timeout, 0, :no_tool_calls}]}
    else
      # Start tool execution asynchronously
      start_tool_execution(tool_calls, data)
    end
  end

  def handle_event(:enter, _old_state, _state, _data) do
    # Default entry handler - do nothing
    :keep_state_and_data
  end

  # Handle deferred idle transition from executing_tools enter handler
  def handle_event(:timeout, :no_tool_calls, :executing_tools, data) do
    handle_idle_transition(data, :executing_tools)
  end

  def handle_event(:cast, {:prompt, text}, :idle, data) do
    Logger.info("#{log_prefix(data.session_id)} Prompt received, #{String.length(text)} chars")

    # Create user message
    user_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }

    # Append to conversation history and process
    data
    |> Map.put(:messages, data.messages ++ [user_message])
    |> maybe_compact_messages()
    |> tap(fn _ -> notify_om_messages_added(data.session_id, [user_message], data.config) end)
    |> start_provider_stream_transition(:idle, turn_count: 1)
  end

  def handle_event(:cast, {:prompt, text}, state, data) do
    # Queue prompt if not idle
    new_queue = :queue.in(text, data.prompt_queue)
    queue_depth = :queue.len(new_queue)

    Logger.info(
      "#{log_prefix(data.session_id)} Prompt queued (current state: #{state}, queue depth: #{queue_depth})"
    )

    new_data = %{data | prompt_queue: new_queue}
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:inject_skill, definition, args}, :idle, data) do
    # Create system message with skill definition
    system_message = %Message{
      id: generate_message_id(),
      role: :system,
      content: [%Text{text: definition}],
      timestamp: DateTime.utc_now()
    }

    # Notify OM about new message
    notify_om_messages_added(data.session_id, [system_message], data.config)

    # Update data with new message and optionally queue args
    updated_data = add_skill_message_and_queue_args(data, system_message, args)

    # Check if compaction is needed and call provider
    updated_data
    |> maybe_compact_messages()
    |> start_provider_stream_transition(:idle, turn_count: 1, clear_buffers: true)
  end

  def handle_event(:cast, {:inject_skill, definition, args}, _state, data) do
    # Queue skill injection if not idle
    # Use a special marker to distinguish from regular prompts
    new_queue = :queue.in({:skill, definition}, data.prompt_queue)

    # If args provided, also queue them as a follow-up user message
    new_queue =
      if args && String.trim(args) != "" do
        :queue.in(args, new_queue)
      else
        new_queue
      end

    new_data = %{data | prompt_queue: new_queue}
    {:keep_state, new_data}
  end

  def handle_event(:cast, :abort, state, data) do
    Logger.info("#{log_prefix(data.session_id)} Abort requested (current state: #{state})")

    # Cancel any in-flight operations based on current state
    _ = cancel_operations_for_abort(state, data)

    # Broadcast abort event
    broadcast_event(data.session_id, {:abort, state})

    # Clean up state and transition to idle
    clean_data = %{
      data
      | stream_ref: nil,
        stream_monitor_ref: nil,
        stream_start_time: nil,
        current_message: nil,
        tool_call_buffers: %{},
        tool_tasks: [],
        compaction_task_ref: nil,
        compaction_task_pid: nil,
        pending_compaction_data: nil
    }

    Logger.debug("#{log_prefix(data.session_id)} State transition: #{state} -> idle")
    {:next_state, :idle, clean_data}
  end

  def handle_event(:cast, {:continue_turn, should_continue}, :executing_tools, data) do
    if should_continue do
      # Reset turn counter and continue calling provider
      new_data = %{data | turn_count: 0}
      continue_after_tools(new_data)
    else
      # User declined to continue - transition to idle
      broadcast_event(data.session_id, {:turn_limit_declined})
      handle_idle_transition(data, :executing_tools)
    end
  end

  # Split handle_event(:calling) into pattern-matched function heads
  def handle_event(:info, {:provider_event, %TextDelta{delta: delta}}, :calling, data) do
    handle_calling_text_delta(delta, data)
  end

  def handle_event(:info, {:provider_event, %ThinkingDelta{delta: delta}}, :calling, data) do
    handle_calling_thinking_delta(delta, data)
  end

  def handle_event(:info, {:provider_event, %ToolCallStart{id: id, name: name}}, :calling, data) do
    handle_calling_tool_start(id, name, data)
  end

  def handle_event(:info, {:provider_event, %Error{} = error_event}, :calling, data) do
    handle_calling_error(error_event, data)
  end

  def handle_event(:info, {:provider_event, %Usage{} = usage_event}, :calling, data) do
    handle_usage(usage_event, data)
  end

  def handle_event(:info, {:provider_event, %Done{}}, :calling, data) do
    handle_calling_done(data)
  end

  def handle_event(:info, {:provider_event, _event}, :calling, _data) do
    # Other events - keep waiting for first content
    :keep_state_and_data
  end

  def handle_event(:info, {:retry_stream}, :calling, data) do
    # Retry after exponential backoff delay
    # Check if compaction is needed before retrying
    compacted_data = maybe_compact_messages(data)

    context_messages =
      Context.build(compacted_data.messages,
        config: compacted_data.config,
        session_id: compacted_data.session_id
      )

    provider = Map.get(compacted_data.config, :provider)
    tools = Map.get(compacted_data.config, :tools, [])

    # Add session_id to config for provider logging
    config_with_session = Map.put(compacted_data.config, :session_id, compacted_data.session_id)

    case call_provider_stream(
           provider,
           context_messages,
           tools,
           config_with_session,
           compacted_data.rate_limiter
         ) do
      {:ok, stream_ref, updated_config} ->
        # Monitor the stream process to detect crashes (only if stream_ref is a PID)
        monitor_ref = if is_pid(stream_ref), do: Process.monitor(stream_ref), else: nil

        # Update stream ref and config (with estimated tokens if rate limited), keep retry count
        new_data = %{
          compacted_data
          | stream_ref: stream_ref,
            stream_monitor_ref: monitor_ref,
            config: updated_config
        }

        {:keep_state, new_data}

      {:error, reason} ->
        handle_calling_error(%{message: inspect(reason)}, compacted_data)
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :calling, data) do
    cond do
      ref == data.stream_monitor_ref ->
        # Stream process crashed while waiting for first content
        Logger.error(
          "#{log_prefix(data.session_id)} Provider connection failure: stream process crashed: #{inspect(reason)}"
        )

        broadcast_event(data.session_id, {:error, "Stream process crashed: #{inspect(reason)}"})

        new_data = %{
          data
          | stream_ref: nil,
            stream_monitor_ref: nil,
            stream_start_time: nil
        }

        handle_idle_transition(new_data, :calling)

      ref == data.compaction_task_ref ->
        # Compaction task failed - log and continue without compaction
        broadcast_event(data.session_id, {:compaction_failed, inspect(reason)})

        new_data = %{
          data
          | compaction_task_ref: nil,
            compaction_task_pid: nil,
            pending_compaction_data: nil
        }

        {:keep_state, new_data}

      true ->
        # Not our monitor, ignore
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:provider_event, %TextDelta{} = event}, :streaming, data) do
    handle_text_delta(event, data)
  end

  def handle_event(:info, {:provider_event, %ThinkingDelta{} = event}, :streaming, data) do
    handle_thinking_delta(event, data)
  end

  def handle_event(:info, {:provider_event, %ToolCallStart{} = event}, :streaming, data) do
    handle_tool_call_start(event, data)
  end

  def handle_event(:info, {:provider_event, %ToolCallDelta{} = event}, :streaming, data) do
    handle_tool_call_delta(event, data)
  end

  def handle_event(:info, {:provider_event, %ToolCallDone{} = event}, :streaming, data) do
    handle_tool_call_done(event, data)
  end

  def handle_event(:info, {:provider_event, %Usage{} = event}, :streaming, data) do
    handle_usage(event, data)
  end

  def handle_event(:info, {:provider_event, %Done{}}, :streaming, data) do
    handle_stream_done(data)
  end

  def handle_event(:info, {:provider_event, %Error{} = event}, :streaming, data) do
    handle_stream_error(event, data)
  end

  def handle_event(:info, {:provider_event, _event}, :streaming, _data) do
    # Unrecognized event - ignore
    :keep_state_and_data
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :streaming, data) do
    cond do
      ref == data.stream_monitor_ref ->
        # Stream process crashed during streaming - treat as error and retry
        error_payload = %{message: "Stream process crashed: #{inspect(reason)}"}
        handle_stream_error(error_payload, data)

      ref == data.compaction_task_ref ->
        # Compaction task failed - log and continue without compaction
        broadcast_event(data.session_id, {:compaction_failed, inspect(reason)})

        new_data = %{
          data
          | compaction_task_ref: nil,
            compaction_task_pid: nil,
            pending_compaction_data: nil
        }

        {:keep_state, new_data}

      true ->
        # Not our monitor, ignore
        :keep_state_and_data
    end
  end

  def handle_event(:info, {ref, results}, :executing_tools, %{tool_tasks: tasks} = data)
      when is_reference(ref) do
    cond do
      # Check if it's a tool execution task
      Enum.find(tasks, fn task -> task.ref == ref end) != nil ->
        handle_tool_execution_complete(ref, results, data)

      # Check if it's the compaction task
      ref == data.compaction_task_ref ->
        handle_compaction_complete(results, data)

      true ->
        # Not our task, ignore
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :executing_tools, data) do
    cond do
      # Check if it's a tool execution task
      Enum.find(data.tool_tasks, fn task -> task.ref == ref end) != nil ->
        # Tool execution task crashed/shutdown - transition to idle
        Logger.error("#{log_prefix(data.session_id)} Tool execution crashed: #{inspect(reason)}")

        broadcast_event(
          data.session_id,
          {:error, "Tool execution was interrupted"}
        )

        new_data = %{data | tool_tasks: []}
        handle_idle_transition(new_data, :executing_tools)

      ref == data.compaction_task_ref ->
        # Compaction task failed - log and continue without compaction
        broadcast_event(data.session_id, {:compaction_failed, inspect(reason)})

        new_data = %{
          data
          | compaction_task_ref: nil,
            compaction_task_pid: nil,
            pending_compaction_data: nil
        }

        {:keep_state, new_data}

      true ->
        # Not our task, ignore
        :keep_state_and_data
    end
  end

  # Handle compaction task completion in any other state (idle, calling, streaming)
  def handle_event(:info, {ref, result}, _state, data) when is_reference(ref) do
    if ref == data.compaction_task_ref do
      handle_compaction_complete(result, data)
    else
      # Not our task, ignore
      :keep_state_and_data
    end
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

  # Shared helper to start provider stream and transition to :calling state
  # Used by handle_event(:prompt), handle_event(:inject_skill), process_queued_message, continue_after_tools
  defp start_provider_stream_transition(data, from_state, opts) do
    context_messages =
      Context.build(data.messages, config: data.config, session_id: data.session_id)

    provider = Map.get(data.config, :provider)
    tools = Map.get(data.config, :tools, [])
    config_with_session = Map.put(data.config, :session_id, data.session_id)

    case call_provider_stream(
           provider,
           context_messages,
           tools,
           config_with_session,
           data.rate_limiter
         ) do
      {:ok, stream_ref, updated_config} ->
        log_provider_stream_started(data.session_id, provider, config_with_session)
        new_data = build_calling_state_data(data, stream_ref, opts)
        # Update config with estimated tokens if rate limited
        new_data = %{new_data | config: updated_config}
        broadcast_event(data.session_id, {:state_change, :calling})
        Logger.debug("#{log_prefix(data.session_id)} State transition: #{from_state} -> calling")
        {:next_state, :calling, new_data}

      {:error, reason} ->
        broadcast_event(data.session_id, {:error, reason})

        if from_state == :idle,
          do: :keep_state_and_data,
          else: handle_idle_transition(data, from_state)
    end
  end

  defp log_provider_stream_started(session_id, provider, config) do
    provider_name = if provider, do: inspect(provider), else: "nil"
    model = Map.get(config, :model, "unknown")
    Logger.info("#{log_prefix(session_id)} Provider stream started (#{provider_name}, #{model})")
  end

  defp build_calling_state_data(data, stream_ref, opts) do
    monitor_ref = if is_pid(stream_ref), do: Process.monitor(stream_ref), else: nil
    turn_count = Keyword.get(opts, :turn_count, data.turn_count + 1)
    clear_buffers = Keyword.get(opts, :clear_buffers, false)

    base_data = %{
      data
      | stream_ref: stream_ref,
        stream_monitor_ref: monitor_ref,
        retry_count: 0,
        retry_delay: 1000,
        turn_count: turn_count
    }

    base_data =
      if Keyword.has_key?(opts, :turn_count) do
        %{
          base_data
          | stream_start_time: System.monotonic_time(:millisecond),
            turn_start_time: System.monotonic_time(:millisecond)
        }
      else
        base_data
      end

    if clear_buffers do
      %{base_data | current_message: nil, tool_call_buffers: %{}}
    else
      base_data
    end
  end

  defp add_skill_message_and_queue_args(data, system_message, args) do
    new_messages = data.messages ++ [system_message]

    if args && String.trim(args) != "" do
      new_queue = :queue.in(args, data.prompt_queue)
      %{data | messages: new_messages, prompt_queue: new_queue}
    else
      %{data | messages: new_messages}
    end
  end

  # Handle :calling state events - split into separate functions
  defp handle_calling_text_delta(delta, data) do
    current_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [%Deft.Message.Text{text: delta}],
      timestamp: DateTime.utc_now()
    }

    new_data = %{data | current_message: current_message}
    broadcast_event(data.session_id, {:text_delta, delta})
    broadcast_event(data.session_id, {:state_change, :streaming})
    Logger.debug("#{log_prefix(data.session_id)} State transition: calling -> streaming")
    {:next_state, :streaming, new_data}
  end

  defp handle_calling_thinking_delta(delta, data) do
    current_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [],
      timestamp: DateTime.utc_now()
    }

    new_data = %{data | current_message: current_message}
    broadcast_event(data.session_id, {:thinking_delta, delta})
    broadcast_event(data.session_id, {:state_change, :streaming})
    Logger.debug("#{log_prefix(data.session_id)} State transition: calling -> streaming")
    {:next_state, :streaming, new_data}
  end

  defp handle_calling_tool_start(id, name, data) do
    tool_use = %Deft.Message.ToolUse{id: id, name: name, args: %{}}

    current_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [tool_use],
      timestamp: DateTime.utc_now()
    }

    tool_call_buffers = Map.get(data, :tool_call_buffers, %{})
    new_buffers = Map.put(tool_call_buffers, id, "")
    new_data = %{data | current_message: current_message, tool_call_buffers: new_buffers}

    broadcast_event(data.session_id, {:tool_call_start, %{id: id, name: name}})
    broadcast_event(data.session_id, {:state_change, :streaming})
    Logger.debug("#{log_prefix(data.session_id)} State transition: calling -> streaming")
    {:next_state, :streaming, new_data}
  end

  defp handle_calling_done(data) do
    if data.stream_monitor_ref, do: Process.demonitor(data.stream_monitor_ref, [:flush])

    new_data = %{
      data
      | stream_ref: nil,
        stream_monitor_ref: nil,
        stream_start_time: nil,
        retry_count: 0,
        retry_delay: 1000
    }

    handle_idle_transition(new_data, :calling)
  end

  defp get_context_window(config) do
    # Get context window from provider's model config
    provider = Map.get(config, :provider)
    model = Map.get(config, :model, "claude-sonnet-4-20250514")

    if provider && function_exported?(provider, :model_config, 1) do
      case provider.model_config(model) do
        %{context_window: window} -> window
        {:error, _} -> 200_000
      end
    else
      # Default to 200k if provider not available
      200_000
    end
  end

  defp calculate_cost(config, input_tokens, output_tokens) do
    # Calculate cost from usage tokens using model pricing
    provider = Map.get(config, :provider)
    model = Map.get(config, :model, "claude-sonnet-4-20250514")

    if provider && function_exported?(provider, :model_config, 1) do
      case provider.model_config(model) do
        %{input_price_per_mtok: input_price, output_price_per_mtok: output_price} ->
          # Price is per million tokens (mtok)
          input_cost = input_tokens * input_price / 1_000_000
          output_cost = output_tokens * output_price / 1_000_000
          input_cost + output_cost

        {:error, _} ->
          # If model config not available, return 0.0
          0.0
      end
    else
      # If provider not available, return 0.0
      0.0
    end
  end

  defp generate_message_id do
    # Generate a unique message ID using UUID
    "msg_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp log_prefix(session_id) do
    # Get first 8 chars of session ID for log prefix
    prefix = String.slice(session_id, 0, 8)
    "[Agent:#{prefix}]"
  end

  # Token estimation for rate limiting
  # Uses simple heuristic of 4 characters per token
  @chars_per_token 4

  defp estimate_message_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_single_message_tokens/1)
    |> Enum.sum()
  end

  defp estimate_single_message_tokens(%{content: content}) when is_binary(content) do
    div(String.length(content), @chars_per_token)
  end

  defp estimate_single_message_tokens(%{content: content}) when is_list(content) do
    content
    |> Enum.map(&estimate_content_block_tokens/1)
    |> Enum.sum()
  end

  defp estimate_single_message_tokens(_), do: 0

  defp estimate_content_block_tokens(%Text{text: text}) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  defp estimate_content_block_tokens(%{text: text}) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  defp estimate_content_block_tokens(_), do: 0

  defp call_provider_stream(nil, _messages, _tools, _config, _rate_limiter) do
    # No provider configured
    {:error, :no_provider}
  end

  defp call_provider_stream(provider, messages, tools, config, nil) do
    # No rate limiter - proceed directly
    wrap_stream_result(provider.stream(messages, tools, config), config)
  end

  defp call_provider_stream(provider, messages, tools, config, rate_limiter) do
    # Rate limiter configured - request capacity first
    estimated_tokens = estimate_message_tokens(messages)
    priority = 1

    case request_rate_limit(rate_limiter, provider, estimated_tokens, priority) do
      {:ok, estimated_tokens} ->
        config_with_estimate = Map.put(config, :_estimated_tokens, estimated_tokens)

        wrap_stream_result(
          provider.stream(messages, tools, config_with_estimate),
          config_with_estimate
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp request_rate_limit(rate_limiter, provider, estimated_tokens, priority) do
    case GenServer.call(rate_limiter, {:request, provider, estimated_tokens, priority}, :infinity) do
      {:ok, _estimated_tokens} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("Rate limiter denied request: #{inspect(reason)}")
        error
    end
  end

  defp wrap_stream_result({:ok, stream_ref}, config), do: {:ok, stream_ref, config}
  defp wrap_stream_result(error, _config), do: error

  # Notify OM.State about new messages added
  # Per spec section 3, called after each turn with new messages
  defp notify_om_messages_added(session_id, messages, config) do
    # Check if OM is enabled
    om_enabled = Map.get(config, :om_enabled, true)

    if om_enabled do
      # Check if OM.State process exists for this session
      case Registry.lookup(Deft.ProcessRegistry, {:om_state, session_id}) do
        [{_pid, _}] ->
          # Process exists, safe to call
          OMState.messages_added(session_id, messages)

        [] ->
          # OM.State process doesn't exist - session not initialized with OM
          :ok
      end
    else
      :ok
    end
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

      error_message = Map.get(error_payload, :message, "Unknown error")

      Logger.warning(
        "#{log_prefix(data.session_id)} Stream error (retry #{retry_count}/#{max_retries}): #{error_message}"
      )

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

      Logger.error(
        "#{log_prefix(data.session_id)} Provider failure after #{max_retries} retries: #{error_message}"
      )

      broadcast_event(
        data.session_id,
        {:error, "Failed after #{max_retries} retries: #{error_message}"}
      )

      # Reset retry state and transition to idle
      new_data = %{
        data
        | stream_ref: nil,
          stream_start_time: nil,
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
    # current_context_tokens represents the actual context sent to the LLM (input tokens)
    # Calculate cost from usage tokens
    turn_cost = calculate_cost(data.config, input_tokens, output_tokens)
    new_session_cost = data.session_cost + turn_cost

    # Reconcile rate limiter if configured
    if data.rate_limiter do
      provider = Map.get(data.config, :provider)
      estimated_tokens = Map.get(data.config, :_estimated_tokens, 0)
      actual_usage = %{input: input_tokens, output: output_tokens}
      GenServer.cast(data.rate_limiter, {:reconcile, provider, estimated_tokens, actual_usage})
    end

    new_data = %{
      data
      | total_input_tokens: data.total_input_tokens + input_tokens,
        total_output_tokens: data.total_output_tokens + output_tokens,
        current_context_tokens: input_tokens,
        session_cost: new_session_cost
    }

    # Persist cost entry to session JSONL
    cost_entry = Cost.new(new_session_cost)
    working_dir = Map.get(data.config, :working_dir, File.cwd!())

    case Store.append(data.session_id, cost_entry, working_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{log_prefix(data.session_id)} Failed to append cost entry to session: #{inspect(reason)}"
        )
    end

    broadcast_event(
      data.session_id,
      {:usage, %{input: input_tokens, output: output_tokens, cost: turn_cost}}
    )

    {:keep_state, new_data}
  end

  defp handle_stream_done(data) do
    duration_ms =
      if data.stream_start_time do
        System.monotonic_time(:millisecond) - data.stream_start_time
      else
        nil
      end

    duration_str = if duration_ms, do: " (#{duration_ms}ms)", else: ""
    Logger.info("#{log_prefix(data.session_id)} Provider stream complete#{duration_str}")

    # Demonitor the stream process
    if data.stream_monitor_ref do
      Process.demonitor(data.stream_monitor_ref, [:flush])
    end

    # Finalize the assistant message and transition to :executing_tools
    finalized_message = data.current_message
    new_messages = data.messages ++ [finalized_message]

    # Notify OM about new assistant message
    notify_om_messages_added(data.session_id, [finalized_message], data.config)

    new_data = %{
      data
      | messages: new_messages,
        current_message: nil,
        stream_ref: nil,
        stream_monitor_ref: nil,
        stream_start_time: nil,
        tool_call_buffers: %{},
        retry_count: 0,
        retry_delay: 1000
    }

    # Check if the assistant message contains tool calls
    tool_calls = extract_tool_calls(new_data.messages)

    if Enum.empty?(tool_calls) do
      # No tool calls — go directly to idle (skip executing_tools state)
      handle_idle_transition(new_data, :streaming)
    else
      broadcast_event(data.session_id, {:state_change, :executing_tools})

      Logger.debug(
        "#{log_prefix(data.session_id)} State transition: streaming -> executing_tools"
      )

      {:next_state, :executing_tools, new_data}
    end
  end

  defp handle_stream_error(error_payload, data) do
    error_msg = Map.get(error_payload, :message, "Unknown error")
    Logger.warning("#{log_prefix(data.session_id)} Stream error: #{error_msg}")

    max_retries = 3

    # Demonitor the stream process
    if data.stream_monitor_ref do
      Process.demonitor(data.stream_monitor_ref, [:flush])
    end

    # Reset partial state from streaming
    reset_data = %{
      data
      | current_message: nil,
        stream_ref: nil,
        stream_monitor_ref: nil,
        stream_start_time: nil,
        tool_call_buffers: %{}
    }

    if reset_data.retry_count < max_retries do
      # Schedule retry with exponential backoff
      retry_count = reset_data.retry_count + 1
      delay = reset_data.retry_delay

      # Send delayed message to self for retry
      Process.send_after(self(), {:retry_stream}, delay)

      new_data = %{
        reset_data
        | retry_count: retry_count,
          retry_delay: delay * 2
      }

      broadcast_event(data.session_id, {:retry, retry_count, max_retries, delay})
      # Transition to :calling state so the retry handler can re-call the provider
      {:next_state, :calling, new_data}
    else
      # Max retries exceeded - transition to idle with error
      error_message = Map.get(error_payload, :message, "Unknown streaming error")

      Logger.error(
        "#{log_prefix(data.session_id)} Unrecoverable provider failure after #{max_retries} retries: #{error_message}"
      )

      broadcast_event(
        data.session_id,
        {:error, "Failed after #{max_retries} retries: #{error_message}"}
      )

      # Reset retry state and transition to idle
      new_data = %{
        reset_data
        | retry_count: 0,
          retry_delay: 1000
      }

      {:next_state, :idle, new_data}
    end
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

  defp extract_tool_calls(messages) do
    # Extract all ToolUse blocks from the last assistant message
    alias Deft.Message.ToolUse

    case List.last(messages) do
      %Message{role: :assistant, content: content} ->
        Enum.filter(content, fn
          %ToolUse{} -> true
          _ -> false
        end)

      _ ->
        []
    end
  end

  defp handle_idle_transition(data, from_state) do
    data_with_saved = save_unsaved_messages(data)

    case :queue.out(data_with_saved.prompt_queue) do
      {{:value, {:skill, definition}}, new_queue} ->
        create_system_message(definition)
        |> then(&process_queued_message(&1, new_queue, data_with_saved))

      {{:value, text}, new_queue} when is_binary(text) ->
        create_user_message(text)
        |> then(&process_queued_message(&1, new_queue, data_with_saved))

      {:empty, _} ->
        complete_turn_and_transition_idle(data_with_saved, from_state)
    end
  end

  defp create_system_message(text) do
    %Message{
      id: generate_message_id(),
      role: :system,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  defp create_user_message(text) do
    %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  defp complete_turn_and_transition_idle(data, from_state) do
    turn_duration_ms = calculate_turn_duration(data)
    Logger.info("#{log_prefix(data.session_id)} Turn complete (#{turn_duration_ms}ms)")
    broadcast_event(data.session_id, {:state_change, :idle})
    Logger.debug("#{log_prefix(data.session_id)} State transition: #{from_state} -> idle")
    {:next_state, :idle, data}
  end

  defp calculate_turn_duration(data) do
    if data.turn_start_time do
      System.monotonic_time(:millisecond) - data.turn_start_time
    else
      0
    end
  end

  defp process_queued_message(message, new_queue, data) do
    queue_depth = :queue.len(new_queue)

    Logger.debug(
      "#{log_prefix(data.session_id)} Processing queued prompt (remaining queue depth: #{queue_depth})"
    )

    # Update data with new message and queue, notify OM, and start provider stream
    data
    |> Map.put(:prompt_queue, new_queue)
    |> Map.put(:messages, data.messages ++ [message])
    |> tap(fn updated ->
      notify_om_messages_added(updated.session_id, [message], updated.config)
    end)
    |> maybe_compact_messages()
    |> start_provider_stream_transition(:idle, turn_count: 1)
  end

  defp cancel_operations_for_abort(state, data) do
    # Cancel state-specific operations
    cancel_state_operations(state, data)
    # Cancel compaction task if in progress (applies to all states)
    cancel_compaction_task(data)
  end

  defp cancel_state_operations(state, data) when state in [:calling, :streaming] do
    # Cancel the stream if we have a stream ref and provider
    if data.stream_ref && Map.get(data.config, :provider) do
      provider = Map.get(data.config, :provider)
      provider.cancel_stream(data.stream_ref)
    end

    # Demonitor the stream process
    if data.stream_monitor_ref do
      Process.demonitor(data.stream_monitor_ref, [:flush])
    end
  end

  defp cancel_state_operations(:executing_tools, data) do
    # Terminate all in-flight tool execution tasks
    tool_runner = get_tool_runner_supervisor(data)

    if tool_runner do
      # Terminate ALL children of the supervisor to catch both wrapper tasks
      # and inner per-tool tasks spawned by ToolRunner.execute_batch
      Task.Supervisor.children(tool_runner)
      |> Enum.each(fn pid ->
        Task.Supervisor.terminate_child(tool_runner, pid)
      end)
    end
  end

  defp cancel_state_operations(_state, _data) do
    # No active operations to cancel in other states
    :ok
  end

  defp cancel_compaction_task(data) do
    if data.compaction_task_pid do
      tool_runner = get_tool_runner_supervisor(data)

      if tool_runner do
        Task.Supervisor.terminate_child(tool_runner, data.compaction_task_pid)
      end
    end
  end

  defp get_tool_runner_supervisor(data) do
    # Look up the ToolRunner Task.Supervisor from the session worker supervision tree
    via_tuple = Worker.tool_runner_via_tuple(data.session_id)
    GenServer.whereis(via_tuple)
  end

  defp get_cache_tid(session_id, lead_id \\ "main") do
    # Get the cache Store's ETS tid for direct reads
    cache_server = Worker.cache_via_tuple(session_id, lead_id)

    case GenServer.whereis(cache_server) do
      nil ->
        # Cache not available (shouldn't happen in normal operation)
        nil

      _pid ->
        # Get tid from the Store
        Deft.Store.tid(cache_server)
    end
  end

  defp build_tool_context(data) do
    # Build a Deft.Tool.Context struct for tool execution
    # Extract cache configuration from config
    config = data.config
    lead_id = Map.get(data, :lead_id, "main")

    cache_config = %{
      "default" => Map.get(config, :cache_token_threshold, 10_000),
      "read" => Map.get(config, :cache_token_threshold_read, 20_000),
      "grep" => Map.get(config, :cache_token_threshold_grep, 8_000),
      "ls" => Map.get(config, :cache_token_threshold_ls, 4_000),
      "find" => Map.get(config, :cache_token_threshold_find, 4_000)
    }

    # Get cache tid from the Store instance
    cache_tid = get_cache_tid(data.session_id, lead_id)

    %Deft.Tool.Context{
      working_dir: Map.get(data.config, :working_dir, File.cwd!()),
      session_id: data.session_id,
      lead_id: lead_id,
      emit: fn _output -> :ok end,
      file_scope: nil,
      parent_pid: data.parent_pid,
      bash_timeout: Map.get(data.config, :bash_timeout, 120_000),
      cache_tid: cache_tid,
      cache_config: cache_config
    }
  end

  defp maybe_activate_cache_read(data) do
    # Check if cache_active is already true
    cache_active = Map.get(data.config, :cache_active, false)

    # Already active, no changes needed
    if cache_active, do: data, else: activate_cache_read_if_needed(data)
  end

  defp activate_cache_read_if_needed(data) do
    # Check if cache has entries
    cache_tid = get_cache_tid(data.session_id)

    # No cache available
    if is_nil(cache_tid), do: data, else: check_cache_and_activate(data, cache_tid)
  end

  defp check_cache_and_activate(data, cache_tid) do
    keys = Deft.Store.keys(cache_tid)

    # No cache entries yet
    if length(keys) == 0 do
      data
    else
      # Cache has entries - activate cache_read
      tools = Map.get(data.config, :tools, [])

      # Add CacheRead if not already present
      updated_tools =
        if Deft.Tools.CacheRead in tools do
          tools
        else
          [Deft.Tools.CacheRead | tools]
        end

      updated_config =
        data.config
        |> Map.put(:cache_active, true)
        |> Map.put(:tools, updated_tools)

      %{data | config: updated_config}
    end
  end

  defp start_tool_execution(tool_calls, data) do
    # Execute tools concurrently via ToolRunner
    # Get the ToolRunner supervisor from the session worker
    tool_count = length(tool_calls)
    tool_names = Enum.map(tool_calls, & &1.name) |> Enum.join(", ")

    Logger.info(
      "#{log_prefix(data.session_id)} Tool execution started (#{tool_count} tools: #{tool_names})"
    )

    tool_timeout = Map.get(data.config, :tool_timeout, 120_000)

    # Record start times for each tool call
    start_time = System.monotonic_time(:millisecond)

    execution_times =
      Enum.reduce(tool_calls, data.tool_execution_times, fn tool_use, acc ->
        Map.put(acc, tool_use.id, start_time)
      end)

    # Get the ToolRunner Task.Supervisor
    tool_runner = get_tool_runner_supervisor(data)

    if tool_runner do
      # Start execution asynchronously with Task.Supervisor.async_nolink
      # This prevents blocking the gen_statem and allows abort to work
      # async_nolink provides isolation - a crash in execute_tools_in_task won't propagate to the agent
      task =
        Task.Supervisor.async_nolink(tool_runner, fn ->
          execute_tools_in_task(tool_calls, data, tool_timeout)
        end)

      # Store the task info (both ref and pid) and execution times
      task_info = %{ref: task.ref, pid: task.pid}
      new_data = %{data | tool_tasks: [task_info], tool_execution_times: execution_times}
      {:keep_state, new_data}
    else
      # No ToolRunner supervisor available - execute inline and return error results
      results =
        Enum.map(tool_calls, fn tool_use ->
          {tool_use.id,
           {:error, "Tool execution not available (ToolRunner supervisor not started)"}}
        end)

      # Process the error results immediately
      handle_tool_execution_complete(nil, results, %{
        data
        | tool_execution_times: execution_times
      })
    end
  end

  defp execute_tools_in_task(tool_calls, data, tool_timeout) do
    tool_runner = get_tool_runner_supervisor(data)
    tool_context = build_tool_context(data)
    tools = Map.get(data.config, :tools, [])

    if tool_runner do
      ToolRunner.execute_batch(tool_runner, tool_calls, tool_context, tools, tool_timeout)
    else
      # No supervisor available - execute inline with error results
      Enum.map(tool_calls, fn tool_use ->
        {tool_use.id,
         {:error, "Tool execution not available (ToolRunner supervisor not started)"}}
      end)
    end
  end

  defp calculate_batch_duration(results, tool_execution_times, end_time) do
    # Get batch start time from the first tool (all tools in a batch have the same start time)
    batch_start_time =
      case results do
        [{tool_use_id, _} | _] -> Map.get(tool_execution_times, tool_use_id, end_time)
        [] -> end_time
      end

    end_time - batch_start_time
  end

  defp handle_tool_execution_complete(ref, results, data) do
    if ref, do: Process.demonitor(ref, [:flush])

    end_time = System.monotonic_time(:millisecond)
    batch_duration_ms = calculate_batch_duration(results, data.tool_execution_times, end_time)
    log_tool_execution_complete(data.session_id, results, batch_duration_ms)

    tool_calls = extract_tool_calls(data.messages)

    tool_results_with_timing =
      add_timing_to_results(results, tool_calls, data.tool_execution_times, end_time)

    log_tool_crashes(data.session_id, tool_results_with_timing)
    broadcast_tool_completion_events(data.session_id, tool_results_with_timing)
    save_tool_results(tool_results_with_timing, data)

    {use_skill_success_results, regular_results} = split_use_skill_results(results, tool_calls)

    messages_to_add =
      build_tool_result_messages(regular_results, use_skill_success_results, tool_calls)

    data
    |> update_messages_after_tool_execution(messages_to_add)
    |> tap(fn _ -> notify_om_messages_added(data.session_id, messages_to_add, data.config) end)
    |> maybe_activate_cache_read()
    |> continue_after_tools()
  end

  defp log_tool_execution_complete(session_id, results, batch_duration_ms) do
    success_count = Enum.count(results, fn {_id, result} -> match?({:ok, _}, result) end)
    failure_count = Enum.count(results, fn {_id, result} -> match?({:error, _}, result) end)

    Logger.info(
      "#{log_prefix(session_id)} Tool execution complete (#{batch_duration_ms}ms, #{success_count} succeeded, #{failure_count} failed)"
    )
  end

  defp log_tool_crashes(session_id, tool_results_with_timing) do
    Enum.each(tool_results_with_timing, fn {_tool_use_id, tool_name, result, _duration_ms} ->
      case result do
        {:error, "Tool crashed: " <> reason} ->
          Logger.error("#{log_prefix(session_id)} Tool crashed: #{tool_name}, reason: #{reason}")

        {:error, "Tool execution error: " <> reason} ->
          Logger.error("#{log_prefix(session_id)} Tool crashed: #{tool_name}, reason: #{reason}")

        _ ->
          :ok
      end
    end)
  end

  defp add_timing_to_results(results, tool_calls, execution_times, end_time) do
    Enum.map(results, fn {tool_use_id, result} ->
      start_time = Map.get(execution_times, tool_use_id, end_time)
      duration_ms = max(0, end_time - start_time)
      tool_name = find_tool_name(tool_use_id, tool_calls)
      {tool_use_id, tool_name, result, duration_ms}
    end)
  end

  defp find_tool_name(tool_use_id, tool_calls) do
    Enum.find_value(tool_calls, "unknown", fn tool_use ->
      if tool_use.id == tool_use_id, do: tool_use.name
    end)
  end

  defp broadcast_tool_completion_events(session_id, tool_results_with_timing) do
    Enum.each(tool_results_with_timing, fn {tool_use_id, tool_name, result, duration_ms} ->
      is_error = match?({:error, _}, result)

      broadcast_event(session_id, {
        :tool_execution_complete,
        %{
          id: tool_use_id,
          name: tool_name,
          success: !is_error,
          duration: duration_ms,
          result: result
        }
      })
    end)
  end

  defp split_use_skill_results(results, tool_calls) do
    Enum.split_with(results, fn {tool_use_id, result} ->
      tool_name = find_tool_name(tool_use_id, tool_calls)
      tool_name == "use_skill" and match?({:ok, _}, result)
    end)
  end

  defp build_tool_result_messages(regular_results, use_skill_success_results, tool_calls) do
    tool_result_message =
      build_combined_tool_result_message(regular_results, use_skill_success_results, tool_calls)

    use_skill_messages = build_use_skill_messages(use_skill_success_results)

    [tool_result_message | use_skill_messages]
    |> Enum.reject(&is_nil/1)
  end

  defp build_combined_tool_result_message(regular_results, use_skill_success_results, tool_calls) do
    if regular_results == [] and use_skill_success_results == [],
      do: nil,
      else: do_build_message(regular_results, use_skill_success_results, tool_calls)
  end

  defp do_build_message(regular_results, use_skill_success_results, tool_calls) do
    regular_tool_results = build_tool_result_blocks(regular_results, tool_calls)
    use_skill_tool_results = build_use_skill_tool_results(use_skill_success_results)
    tool_result_blocks = regular_tool_results ++ use_skill_tool_results

    %Message{
      id: generate_message_id(),
      role: :user,
      content: tool_result_blocks,
      timestamp: DateTime.utc_now()
    }
  end

  defp build_use_skill_tool_results(use_skill_success_results) do
    Enum.map(use_skill_success_results, fn {tool_use_id, _result} ->
      %Deft.Message.ToolResult{
        tool_use_id: tool_use_id,
        name: "use_skill",
        content: "Skill loaded",
        is_error: false
      }
    end)
  end

  defp update_messages_after_tool_execution(data, messages_to_add) do
    %{
      data
      | messages: data.messages ++ messages_to_add,
        tool_tasks: [],
        tool_execution_times: %{}
    }
  end

  defp build_tool_result_blocks(results, tool_calls) do
    Enum.map(results, fn {tool_use_id, result} ->
      tool_name = find_tool_name(tool_use_id, tool_calls)
      build_tool_result_block(tool_use_id, tool_name, result)
    end)
  end

  defp build_tool_result_block(tool_use_id, tool_name, {:ok, content_blocks}) do
    # Content blocks from tool execution - convert to string
    content_text =
      content_blocks
      |> Enum.map(fn
        %Deft.Message.Text{text: text} -> text
        other -> inspect(other)
      end)
      |> Enum.join("\n")

    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: tool_name,
      content: content_text,
      is_error: false
    }
  end

  defp build_tool_result_block(tool_use_id, tool_name, {:error, error_message}) do
    %Deft.Message.ToolResult{
      tool_use_id: tool_use_id,
      name: tool_name,
      content: error_message,
      is_error: true
    }
  end

  defp build_use_skill_messages(use_skill_success_results) do
    # Build system messages from successful use_skill results
    # Each successful use_skill result contains a skill definition that should
    # be injected as a system-level instruction (per spec sections 2.4, 2.5)
    Enum.map(use_skill_success_results, fn {_tool_use_id, {:ok, content_blocks}} ->
      # Extract the skill definition from content blocks
      definition_text =
        content_blocks
        |> Enum.map(fn
          %Deft.Message.Text{text: text} -> text
          other -> inspect(other)
        end)
        |> Enum.join("\n")

      # Inject as a system message (system-level instruction)
      %Message{
        id: generate_message_id(),
        role: :system,
        content: [%Deft.Message.Text{text: definition_text}],
        timestamp: DateTime.utc_now()
      }
    end)
  end

  defp continue_after_tools(data) do
    new_turn_count = data.turn_count + 1
    max_turns = Map.get(data.config, :max_turns, 25)

    if new_turn_count > max_turns do
      handle_turn_limit_reached(data, new_turn_count, max_turns)
    else
      continue_calling_provider(data, new_turn_count)
    end
  end

  defp handle_turn_limit_reached(data, new_turn_count, max_turns) do
    broadcast_event(data.session_id, {:turn_limit_reached, new_turn_count, max_turns})
    updated_data = %{data | turn_count: new_turn_count}
    {:keep_state, updated_data}
  end

  defp continue_calling_provider(data, new_turn_count) do
    data
    |> maybe_compact_messages()
    |> start_provider_stream_transition(:executing_tools, turn_count: new_turn_count)
  end

  # Session persistence helpers

  defp save_unsaved_messages(data) do
    # Find messages that haven't been saved yet
    unsaved_messages =
      Enum.reject(data.messages, fn msg ->
        MapSet.member?(data.saved_message_ids, msg.id)
      end)

    # Save each message to the session file
    working_dir = Map.get(data.config, :working_dir, File.cwd!())

    Enum.each(unsaved_messages, fn msg ->
      entry = Entry.Message.from_message(msg)
      Store.append(data.session_id, entry, working_dir)
    end)

    # Update saved_message_ids set
    new_saved_ids =
      Enum.reduce(unsaved_messages, data.saved_message_ids, fn msg, acc ->
        MapSet.put(acc, msg.id)
      end)

    %{data | saved_message_ids: new_saved_ids}
  end

  defp save_tool_results(tool_results, data) do
    alias Deft.Session.{Entry, Store}

    working_dir = Map.get(data.config, :working_dir, File.cwd!())

    Enum.each(tool_results, fn {tool_use_id, tool_name, result, duration_ms} ->
      is_error = result_is_error?(result)
      result_text = extract_result_text(result)
      entry = Entry.ToolResult.new(tool_use_id, tool_name, result_text, duration_ms, is_error)
      Store.append(data.session_id, entry, working_dir)
    end)

    :ok
  end

  defp result_is_error?({:ok, _}), do: false
  defp result_is_error?({:error, _}), do: true

  defp extract_result_text({:ok, content_blocks}) do
    content_blocks
    |> Enum.map(fn
      %Deft.Message.Text{text: text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp extract_result_text({:error, error_message}), do: error_message

  defp maybe_compact_messages(data) do
    # Check if compaction is needed
    # Compaction is only enabled when OM is disabled
    om_enabled = Map.get(data.config, :om_enabled, true)
    threshold = trunc(data.context_window * 0.7)

    # Skip if compaction is already in progress
    if data.compaction_task_ref != nil do
      data
    else
      if !om_enabled && data.current_context_tokens > threshold do
        # Spawn compaction task instead of blocking
        start_compaction_task(data)
      else
        data
      end
    end
  end

  defp start_compaction_task(data) do
    target_tokens = trunc(data.context_window * 0.5)
    tokens_to_remove = data.current_context_tokens - target_tokens
    avg_tokens_per_message = calculate_avg_tokens_per_message(data)
    messages_to_remove = max(1, div(tokens_to_remove, max(1, avg_tokens_per_message)))

    {system_messages, conversation_messages} = split_system_and_conversation(data.messages)
    {to_remove, to_keep} = Enum.split(conversation_messages, messages_to_remove)

    if length(to_remove) > 0 do
      spawn_compaction_task(data, to_remove, to_keep, system_messages)
    else
      data
    end
  end

  defp calculate_avg_tokens_per_message(data) do
    if length(data.messages) > 0 do
      div(data.current_context_tokens, max(1, length(data.messages)))
    else
      1000
    end
  end

  defp split_system_and_conversation(messages) do
    Enum.split_with(messages, fn msg -> msg.role == :system end)
  end

  defp spawn_compaction_task(data, to_remove, to_keep, system_messages) do
    provider = Map.get(data.config, :provider)
    config = Map.put(data.config, :session_id, data.session_id)
    tool_runner = Worker.tool_runner_via_tuple(data.session_id)

    task =
      Task.Supervisor.async_nolink(tool_runner, fn ->
        summarize_messages_with_llm(to_remove, provider, config)
      end)

    pending_data = %{
      to_remove: to_remove,
      to_keep: to_keep,
      system_messages: system_messages,
      messages_to_remove_count: length(to_remove)
    }

    %{
      data
      | compaction_task_ref: task.ref,
        compaction_task_pid: task.pid,
        pending_compaction_data: pending_data
    }
  end

  defp handle_compaction_complete(result, data) do
    pending = data.pending_compaction_data

    if pending do
      summary_text =
        case result do
          {:ok, summary} ->
            "[Context compaction: #{pending.messages_to_remove_count} messages summarized]\n\n#{summary}"

          {:error, _reason} ->
            "[Context compaction: #{pending.messages_to_remove_count} messages removed to free up context space. " <>
              "Conversation continues from this point.]"
        end

      summary_message = %Message{
        id: generate_message_id(),
        role: :system,
        content: [%Text{text: summary_text}],
        timestamp: DateTime.utc_now()
      }

      # Rebuild messages list with summary
      new_messages = pending.system_messages ++ [summary_message] ++ pending.to_keep

      # Notify OM about summary message
      notify_om_messages_added(data.session_id, [summary_message], data.config)

      broadcast_event(
        data.session_id,
        {:compaction, %{removed: pending.messages_to_remove_count}}
      )

      # Persist compaction entry to session JSONL
      working_dir = Map.get(data.config, :working_dir, File.cwd!())
      compaction_entry = Compaction.new(summary_text, pending.messages_to_remove_count)

      case Store.append(data.session_id, compaction_entry, working_dir) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "#{log_prefix(data.session_id)} Failed to append compaction entry to session: #{inspect(reason)}"
          )
      end

      new_data = %{
        data
        | messages: new_messages,
          compaction_task_ref: nil,
          compaction_task_pid: nil,
          pending_compaction_data: nil
      }

      {:keep_state, new_data}
    else
      # No pending compaction data, just clear the task ref
      {:keep_state, %{data | compaction_task_ref: nil, compaction_task_pid: nil}}
    end
  end

  defp summarize_messages_with_llm(_messages, nil, _config) do
    {:error, :no_provider}
  end

  defp summarize_messages_with_llm(messages, provider, config) do
    # Build summarization prompt
    messages_text =
      messages
      |> Enum.map(fn msg ->
        role = msg.role |> Atom.to_string() |> String.capitalize()
        content = extract_text_content(msg)
        "#{role}: #{content}"
      end)
      |> Enum.join("\n\n")

    summary_prompt =
      "Summarize the following conversation messages concisely, preserving key context and decisions:\n\n#{messages_text}"

    summary_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: summary_prompt}],
      timestamp: DateTime.utc_now()
    }

    # Make streaming call and collect the response
    case provider.stream([summary_message], [], config) do
      {:ok, stream_ref} ->
        collect_stream_text(stream_ref, 30_000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text_content(message) do
    message.content
    |> Enum.filter(fn block -> match?(%Text{}, block) end)
    |> Enum.map(fn %Text{text: text} -> text end)
    |> Enum.join(" ")
  end

  defp collect_stream_text(stream_ref, timeout) do
    collect_stream_text_loop(stream_ref, "", :os.system_time(:millisecond), timeout)
  end

  defp collect_stream_text_loop(stream_ref, acc, start_time, timeout) do
    alias Deft.Provider.Event.{TextDelta, Done, Error}

    elapsed = :os.system_time(:millisecond) - start_time
    remaining_timeout = max(0, timeout - elapsed)

    receive do
      {:provider_event, %TextDelta{delta: delta}} ->
        collect_stream_text_loop(stream_ref, acc <> delta, start_time, timeout)

      {:provider_event, %Done{}} ->
        {:ok, acc}

      {:provider_event, %Error{message: msg}} ->
        {:error, msg}

      {:provider_event, _other} ->
        # Ignore other events (tool calls, thinking, usage, etc.)
        collect_stream_text_loop(stream_ref, acc, start_time, timeout)
    after
      remaining_timeout ->
        # Cancel stream on timeout by terminating the stream process
        if is_pid(stream_ref) and Process.alive?(stream_ref) do
          Process.exit(stream_ref, :timeout)
        end

        {:error, :timeout}
    end
  end
end
