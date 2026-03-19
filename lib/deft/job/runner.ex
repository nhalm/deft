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
  - `job_id` — Job identifier for RateLimiter registry lookup
  - `config` — Configuration map (model, provider, etc.)
  - `worktree_path` — Path to Lead's worktree

  ## Returns

  - `{:ok, output}` — Task completed successfully, output is collected text
  - `{:error, reason}` — Task failed
  """
  def run(type, instructions, context, job_id, config, worktree_path) do
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

    # Start agent loop
    messages = [initial_message]
    loop(messages, tools, tool_context, job_id, provider, config, max_turns: 20)
  rescue
    exception ->
      {:error, "Runner crashed: #{Exception.message(exception)}"}
  end

  # Main agent loop
  defp loop(messages, tools, tool_context, job_id, provider, config, opts) do
    max_turns = Keyword.get(opts, :max_turns, 20)
    current_turn = Keyword.get(opts, :current_turn, 1)

    cond do
      current_turn > max_turns ->
        {:error, "Runner exceeded maximum turns (#{max_turns})"}

      true ->
        do_loop_iteration(
          messages,
          tools,
          tool_context,
          job_id,
          provider,
          config,
          max_turns,
          current_turn
        )
    end
  end

  defp do_loop_iteration(
         messages,
         tools,
         tool_context,
         job_id,
         provider,
         config,
         max_turns,
         current_turn
       ) do
    with {:ok, estimated_tokens} <- request_llm_call(job_id, messages, tools, provider, config),
         {:ok, assistant_message, usage} <- call_provider(messages, tools, provider, config) do
      # Reconcile estimated vs actual token usage
      provider_name = Map.get(config, :provider_name, "anthropic")
      RateLimiter.reconcile(job_id, provider_name, estimated_tokens, usage)

      handle_assistant_message(
        assistant_message,
        messages,
        tools,
        tool_context,
        job_id,
        provider,
        config,
        max_turns,
        current_turn
      )
    else
      {:error, reason} -> {:error, "Call failed: #{reason}"}
    end
  end

  defp handle_assistant_message(
         assistant_message,
         messages,
         tools,
         tool_context,
         job_id,
         provider,
         config,
         max_turns,
         current_turn
       ) do
    if has_tool_calls?(assistant_message) do
      {:ok, tool_result_message} = execute_tools_inline(assistant_message, tools, tool_context)
      result_messages = messages ++ [assistant_message, tool_result_message]

      loop(result_messages, tools, tool_context, job_id, provider, config,
        max_turns: max_turns,
        current_turn: current_turn + 1
      )
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
  defp request_llm_call(job_id, messages, _tools, _provider, config) do
    provider_name = Map.get(config, :provider_name, "anthropic")

    case RateLimiter.request(job_id, provider_name, messages, :runner) do
      {:ok, estimated_tokens} -> {:ok, estimated_tokens}
      {:error, reason} -> {:error, reason}
    end
  end

  # Call provider and collect full response (non-streaming for simplicity)
  defp call_provider(messages, tools, provider, config) do
    # For Runner, we'll use a simplified approach:
    # Start stream and collect all events inline
    case provider.stream(messages, tools, config) do
      {:ok, stream_ref} ->
        collect_stream_events(stream_ref, provider)

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

    tool_call_buffers = %{}
    usage = nil

    collect_loop(stream_ref, current_message, tool_call_buffers, usage, timeout)
  end

  defp collect_loop(stream_ref, current_message, tool_call_buffers, usage, timeout) do
    receive do
      {:provider_event, %TextDelta{delta: text}} ->
        # Append text to content
        new_content = append_text_delta(current_message.content, text)
        new_message = %{current_message | content: new_content}
        collect_loop(stream_ref, new_message, tool_call_buffers, usage, timeout)

      {:provider_event, %ThinkingDelta{}} ->
        # Ignore thinking deltas for now
        collect_loop(stream_ref, current_message, tool_call_buffers, usage, timeout)

      {:provider_event, %ToolCallStart{id: tool_id, name: tool_name}} ->
        # Initialize tool call buffer
        new_buffers = Map.put(tool_call_buffers, tool_id, %{name: tool_name, args_json: ""})
        collect_loop(stream_ref, current_message, new_buffers, usage, timeout)

      {:provider_event, %ToolCallDelta{id: tool_id, delta: args_delta}} ->
        # Append to tool call buffer
        new_buffers =
          Map.update!(tool_call_buffers, tool_id, fn buffer ->
            %{buffer | args_json: buffer.args_json <> args_delta}
          end)

        collect_loop(stream_ref, current_message, new_buffers, usage, timeout)

      {:provider_event, %ToolCallDone{id: tool_id}} ->
        # Finalize tool call
        buffer = Map.fetch!(tool_call_buffers, tool_id)

        case Jason.decode(buffer.args_json) do
          {:ok, args} ->
            tool_use = %ToolUse{
              id: tool_id,
              name: buffer.name,
              args: args
            }

            new_content = current_message.content ++ [tool_use]
            new_message = %{current_message | content: new_content}
            collect_loop(stream_ref, new_message, tool_call_buffers, usage, timeout)

          {:error, _} ->
            {:error, "Failed to parse tool arguments for #{tool_id}"}
        end

      {:provider_event, %Usage{input: input_tokens, output: output_tokens}} ->
        # Capture usage for reconciliation
        new_usage = %{input: input_tokens, output: output_tokens}
        collect_loop(stream_ref, current_message, tool_call_buffers, new_usage, timeout)

      {:provider_event, %Done{}} ->
        # Stream complete - return message and usage
        {:ok, current_message, usage}

      {:provider_event, %Error{message: error_msg}} ->
        {:error, error_msg}
    after
      timeout ->
        {:error, "Stream timeout after #{timeout}ms"}
    end
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
    tool_map = Map.new(tools, fn tool_module -> {tool_module.name(), tool_module} end)

    tool_uses =
      Enum.filter(message.content, fn
        %ToolUse{} -> true
        _ -> false
      end)

    tool_result_blocks =
      Enum.map(tool_uses, fn %ToolUse{id: tool_id, name: tool_name, args: args} = _tool_use ->
        case Map.get(tool_map, tool_name) do
          nil ->
            %ToolResult{
              tool_use_id: tool_id,
              name: tool_name,
              content: "Error: Tool '#{tool_name}' not found",
              is_error: true
            }

          tool_module ->
            try do
              case tool_module.execute(args, tool_context) do
                {:ok, content_blocks} ->
                  # Convert content blocks to string
                  content_text =
                    content_blocks
                    |> Enum.map(fn
                      %Text{text: text} -> text
                      _ -> ""
                    end)
                    |> Enum.join("\n")

                  %ToolResult{
                    tool_use_id: tool_id,
                    name: tool_name,
                    content: content_text,
                    is_error: false
                  }

                {:error, error_msg} ->
                  %ToolResult{
                    tool_use_id: tool_id,
                    name: tool_name,
                    content: error_msg,
                    is_error: true
                  }
              end
            rescue
              exception ->
                %ToolResult{
                  tool_use_id: tool_id,
                  name: tool_name,
                  content: "Tool execution error: #{Exception.message(exception)}",
                  is_error: true
                }
            end
        end
      end)

    result_message = %Message{
      id: generate_message_id(),
      role: :user,
      content: tool_result_blocks,
      timestamp: DateTime.utc_now()
    }

    {:ok, result_message}
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
