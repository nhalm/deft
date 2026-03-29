defmodule Deft.Job.Runner do
  @moduledoc """
  Inline agent loop for short-lived task execution.

  Runners are lightweight, stateless task executors. They:
  - Build minimal context from task instructions
  - Call LLM through RateLimiter
  - Parse tool calls from provider events
  - Execute tools inline with try/catch
  - Loop until done or error
  - Return results via Task return value

  ## Design

  - No gen_statem, no OM — simple inline loop
  - Spawned via Task.Supervisor.async_nolink
  - Timeout enforced by Lead via Process.send_after
  - Different tool sets per runner type
  - All LLM calls through RateLimiter

  ## Runner Types

  - `:research` — read-only tools (read, grep, find, ls)
  - `:implementation` — full tool set (read, write, edit, bash, grep, find, ls)
  - `:testing` — read + bash only (read, bash, grep, find, ls)
  - `:review` — read-only tools (read, grep, find, ls)
  - `:merge_resolution` — conflict resolution (read, write, edit, grep)
  """

  alias Deft.Message
  alias Deft.Message.{Text, ToolUse, ToolResult}

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

  alias Deft.Job.RateLimiter

  require Logger

  @type runner_type :: :research | :implementation | :testing | :review | :merge_resolution
  @type result :: {:ok, String.t()} | {:error, String.t()}

  # Loop context struct to reduce parameter passing
  defmodule LoopContext do
    @moduledoc false
    @enforce_keys [:messages, :tools, :tool_context, :job_id, :provider, :config, :max_turns]
    defstruct [:messages, :tools, :tool_context, :job_id, :provider, :config, :max_turns]

    @type t :: %__MODULE__{
            messages: [Message.t()],
            tools: [module()],
            tool_context: Deft.Tool.Context.t(),
            job_id: Deft.Job.job_id(),
            provider: module(),
            config: map(),
            max_turns: pos_integer()
          }
  end

  # Stream collection state to reduce parameter passing in collect_loop helpers
  defmodule StreamState do
    @moduledoc false
    @enforce_keys [:stream_ref, :current_message, :tool_call_buffers, :usage, :timeout]
    defstruct [:stream_ref, :current_message, :tool_call_buffers, :usage, :timeout]

    @type t :: %__MODULE__{
            stream_ref: reference(),
            current_message: Message.t(),
            tool_call_buffers: map(),
            usage: map() | nil,
            timeout: pos_integer()
          }
  end

  # Tool sets per runner type
  @tool_sets %{
    research: [Deft.Tools.Read, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls],
    implementation: [
      Deft.Tools.Read,
      Deft.Tools.Write,
      Deft.Tools.Edit,
      Deft.Tools.Bash,
      Deft.Tools.Grep,
      Deft.Tools.Find,
      Deft.Tools.Ls
    ],
    testing: [Deft.Tools.Read, Deft.Tools.Bash, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls],
    review: [Deft.Tools.Read, Deft.Tools.Grep, Deft.Tools.Find, Deft.Tools.Ls],
    merge_resolution: [Deft.Tools.Read, Deft.Tools.Write, Deft.Tools.Edit, Deft.Tools.Grep]
  }

  @doc """
  Runs a Runner task inline.

  ## Parameters

  - `type` — Runner type (:research, :implementation, etc.)
  - `instructions` — Task instructions from the Lead
  - `context` — Curated context (findings, contracts, etc.)
  - `opts` — Options map with:
    - `:job_id` — Job identifier for RateLimiter registry lookup
    - `:config` — Configuration map (model, provider, etc.)
    - `:worktree_path` — Path to Lead's worktree

  ## Returns

  - `{:ok, output}` — Task completed successfully, output is collected text
  - `{:error, reason}` — Task failed
  """
  def run(type, instructions, context, opts) do
    job_id = Map.fetch!(opts, :job_id)
    config = Map.fetch!(opts, :config)
    worktree_path = Map.fetch!(opts, :worktree_path)
    # Validate runner type
    tools = Map.get(@tool_sets, type)

    unless tools do
      raise ArgumentError, "Invalid runner type: #{inspect(type)}"
    end

    # Build initial message
    initial_message = build_initial_message(instructions, context)

    # Get provider and model from config
    provider = Map.get(config, :provider)

    if is_nil(provider) do
      raise ArgumentError, "No provider configured in runner config"
    end

    # Build tool context
    tool_context = %Deft.Tool.Context{
      session_id: "runner-#{:erlang.unique_integer([:positive])}",
      working_dir: worktree_path,
      # No-op emit for Runners
      emit: fn _ -> :ok end,
      # 2 minute timeout for bash commands
      bash_timeout: 120_000,
      file_scope: nil,
      cache_tid: nil,
      cache_config: nil
    }

    # Build loop context
    loop_ctx = %LoopContext{
      messages: [initial_message],
      tools: tools,
      tool_context: tool_context,
      job_id: job_id,
      provider: provider,
      config: config,
      max_turns: 20
    }

    # Start agent loop
    loop(loop_ctx, current_turn: 1)
  rescue
    exception ->
      {:error, "Runner crashed: #{Exception.message(exception)}"}
  end

  # Main agent loop
  defp loop(%LoopContext{} = ctx, opts) do
    current_turn = Keyword.get(opts, :current_turn, 1)

    cond do
      current_turn > ctx.max_turns ->
        {:error, "Runner exceeded maximum turns (#{ctx.max_turns})"}

      true ->
        do_loop_iteration(ctx, current_turn)
    end
  end

  defp do_loop_iteration(%LoopContext{} = ctx, current_turn) do
    with {:ok, estimated_tokens} <- request_llm_call(ctx),
         {:ok, assistant_message, usage} <- call_provider(ctx) do
      # Reconcile estimated vs actual token usage
      provider_name = Map.get(ctx.config, :provider_name, "anthropic")
      RateLimiter.reconcile(ctx.job_id, provider_name, estimated_tokens, usage)

      handle_assistant_message(ctx, assistant_message, current_turn)
    else
      {:error, reason} -> {:error, "Call failed: #{reason}"}
    end
  end

  defp handle_assistant_message(%LoopContext{} = ctx, assistant_message, current_turn) do
    if has_tool_calls?(assistant_message) do
      {:ok, tool_result_message} =
        execute_tools_inline(assistant_message, ctx.tools, ctx.tool_context)

      result_messages = ctx.messages ++ [assistant_message, tool_result_message]

      updated_ctx = %{ctx | messages: result_messages}
      loop(updated_ctx, current_turn: current_turn + 1)
    else
      output = extract_text_from_message(assistant_message)
      {:ok, output}
    end
  end

  # Build initial system message with instructions and context
  defp build_initial_message(instructions, context) do
    text = """
    You are a Runner executing a single task.

    # Task

    #{instructions}

    # Context

    #{context}

    # Instructions

    Execute the task using the available tools. When complete, provide a summary of what you did.
    """

    %Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Request permission from rate limiter to make LLM call
  defp request_llm_call(%LoopContext{} = ctx) do
    provider_name = Map.get(ctx.config, :provider_name, "anthropic")

    case RateLimiter.request(ctx.job_id, provider_name, ctx.messages, :runner) do
      {:ok, estimated_tokens} -> {:ok, estimated_tokens}
      {:error, reason} -> {:error, reason}
    end
  end

  # Call provider and collect full response (non-streaming for simplicity)
  defp call_provider(%LoopContext{} = ctx) do
    # For Runner, we'll use a simplified approach:
    # Start stream and collect all events inline
    case ctx.provider.stream(ctx.messages, ctx.tools, ctx.config) do
      {:ok, stream_ref} ->
        collect_stream_events(stream_ref, ctx.provider)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Collect all stream events into a single assistant message
  defp collect_stream_events(stream_ref, _provider, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)

    current_message = %Message{
      id: generate_message_id(),
      role: :assistant,
      content: [],
      timestamp: DateTime.utc_now()
    }

    state = %StreamState{
      stream_ref: stream_ref,
      current_message: current_message,
      tool_call_buffers: %{},
      usage: nil,
      timeout: timeout
    }

    collect_loop(state)
  end

  defp collect_loop(%StreamState{} = state) do
    receive do
      {:provider_event, event} ->
        handle_provider_event(state, event)
    after
      state.timeout ->
        {:error, "Stream timeout after #{state.timeout}ms"}
    end
  end

  defp handle_provider_event(state, %TextDelta{delta: text}), do: handle_text_delta(state, text)
  defp handle_provider_event(state, %ThinkingDelta{}), do: collect_loop(state)

  defp handle_provider_event(state, %ToolCallStart{id: id, name: name}),
    do: handle_tool_call_start(state, id, name)

  defp handle_provider_event(state, %ToolCallDelta{id: id, delta: delta}),
    do: handle_tool_call_delta(state, id, delta)

  defp handle_provider_event(state, %ToolCallDone{id: id}), do: handle_tool_call_done(state, id)

  defp handle_provider_event(state, %Usage{input: input, output: output}),
    do: handle_usage(state, input, output)

  defp handle_provider_event(state, %Done{}), do: {:ok, state.current_message, state.usage}
  defp handle_provider_event(_state, %Error{message: error_msg}), do: {:error, error_msg}

  defp handle_text_delta(%StreamState{} = state, text) do
    new_content = append_text_delta(state.current_message.content, text)
    new_message = %{state.current_message | content: new_content}
    new_state = %{state | current_message: new_message}
    collect_loop(new_state)
  end

  defp handle_tool_call_start(%StreamState{} = state, tool_id, tool_name) do
    new_buffers = Map.put(state.tool_call_buffers, tool_id, %{name: tool_name, args_json: ""})
    new_state = %{state | tool_call_buffers: new_buffers}
    collect_loop(new_state)
  end

  defp handle_tool_call_delta(%StreamState{} = state, tool_id, args_delta) do
    new_buffers =
      Map.update!(state.tool_call_buffers, tool_id, fn buffer ->
        %{buffer | args_json: buffer.args_json <> args_delta}
      end)

    new_state = %{state | tool_call_buffers: new_buffers}
    collect_loop(new_state)
  end

  defp handle_tool_call_done(%StreamState{} = state, tool_id) do
    buffer = Map.fetch!(state.tool_call_buffers, tool_id)

    case Jason.decode(buffer.args_json) do
      {:ok, args} ->
        tool_use = %ToolUse{
          id: tool_id,
          name: buffer.name,
          args: args
        }

        new_content = state.current_message.content ++ [tool_use]
        new_message = %{state.current_message | content: new_content}
        new_state = %{state | current_message: new_message}
        collect_loop(new_state)

      {:error, _} ->
        {:error, "Failed to parse tool arguments for #{tool_id}"}
    end
  end

  defp handle_usage(%StreamState{} = state, input_tokens, output_tokens) do
    new_usage =
      case state.usage do
        nil ->
          %{input: input_tokens, output: output_tokens}

        existing ->
          %{
            input: existing.input + input_tokens,
            output: existing.output + output_tokens
          }
      end

    new_state = %{state | usage: new_usage}
    collect_loop(new_state)
  end

  # Append text delta to content blocks
  defp append_text_delta([], text) do
    [%Text{text: text}]
  end

  defp append_text_delta(content, text) do
    case List.last(content) do
      %Text{} = last_text ->
        List.replace_at(content, -1, %Text{text: last_text.text <> text})

      _ ->
        content ++ [%Text{text: text}]
    end
  end

  # Check if message has tool calls
  defp has_tool_calls?(%Message{content: content}) do
    Enum.any?(content, fn
      %ToolUse{} -> true
      _ -> false
    end)
  end

  # Execute tool calls inline with try/catch
  defp execute_tools_inline(message, tools, tool_context) do
    tool_map = build_tool_map(tools)
    tool_uses = extract_tool_uses(message.content)
    tool_result_blocks = Enum.map(tool_uses, &execute_single_tool(&1, tool_map, tool_context))

    result_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: tool_result_blocks,
      timestamp: DateTime.utc_now()
    }

    {:ok, result_message}
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn tool_module -> {tool_module.name(), tool_module} end)
  end

  defp extract_tool_uses(content) do
    Enum.filter(content, fn
      %ToolUse{} -> true
      _ -> false
    end)
  end

  defp execute_single_tool(
         %ToolUse{id: tool_id, name: tool_name, args: args},
         tool_map,
         tool_context
       ) do
    case Map.get(tool_map, tool_name) do
      nil ->
        build_error_result(tool_id, tool_name, "Error: Tool '#{tool_name}' not found")

      tool_module ->
        try do
          execute_tool_with_module(tool_id, tool_name, args, tool_module, tool_context)
        rescue
          exception ->
            build_error_result(
              tool_id,
              tool_name,
              "Tool execution error: #{Exception.message(exception)}"
            )
        end
    end
  end

  defp execute_tool_with_module(tool_id, tool_name, args, tool_module, tool_context) do
    case tool_module.execute(args, tool_context) do
      {:ok, content_blocks} ->
        content_text = convert_content_blocks_to_text(content_blocks)

        %ToolResult{
          tool_use_id: tool_id,
          name: tool_name,
          content: content_text,
          is_error: false
        }

      {:error, error_msg} ->
        build_error_result(tool_id, tool_name, error_msg)
    end
  end

  defp convert_content_blocks_to_text(content_blocks) do
    content_blocks
    |> Enum.map(fn
      %Text{text: text} -> text
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp build_error_result(tool_id, tool_name, error_msg) do
    %ToolResult{
      tool_use_id: tool_id,
      name: tool_name,
      content: error_msg,
      is_error: true
    }
  end

  # Extract text from assistant message
  defp extract_text_from_message(%Message{content: content}) do
    content
    |> Enum.filter(fn
      %Text{} -> true
      _ -> false
    end)
    |> Enum.map(fn %Text{text: text} -> text end)
    |> Enum.join("\n")
  end

  # Estimate tokens from messages (simple heuristic: chars / 4)
  # Generate unique message ID
  defp generate_message_id do
    "msg-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
