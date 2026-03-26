defmodule Deft.Agent.ToolRunner do
  @moduledoc """
  Task.Supervisor for executing tool calls concurrently.

  Tool execution is supervised and isolated from the agent process. Each tool
  call is executed in its own task via `async_nolink`, and results are collected
  with timeouts via `Task.yield_many/2`.

  Exceptions in tool execution are caught and converted to error results.
  """

  alias Deft.Message.Text
  alias Deft.Store

  require Logger

  @doc """
  Starts the ToolRunner Task.Supervisor.
  """
  def start_link(opts) do
    Task.Supervisor.start_link(opts)
  end

  @doc """
  Returns the child spec for the ToolRunner supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Execute a batch of tool calls concurrently.

  Returns a list of `{tool_use_id, result}` tuples where result is either
  `{:ok, [ContentBlock.t()]}` or `{:error, String.t()}`.

  ## Arguments

  - `supervisor` — The ToolRunner supervisor PID
  - `tool_calls` — List of `%ToolUse{}` blocks to execute
  - `context` — The `Deft.Tool.Context` struct for tool execution
  - `tools` — List of tool modules implementing the `Deft.Tool` behaviour
  - `timeout` — Timeout in milliseconds for each tool (default: 120_000)

  ## Returns

  List of `{tool_use_id, result}` tuples in the same order as tool_calls.
  """
  def execute_batch(supervisor, tool_calls, context, tools, timeout \\ 120_000) do
    # Build tool dispatch map: name -> module
    tool_map = Map.new(tools, fn tool_module -> {tool_module.name(), tool_module} end)

    # Spawn async tasks for each tool call
    tasks =
      Enum.map(tool_calls, fn tool_use ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            execute_tool(tool_use, context, tool_map)
          end)

        {tool_use.id, tool_use.name, task}
      end)

    # Collect results with timeout
    session_prefix = "[Tools:#{String.slice(context.session_id, 0, 8)}]"

    results =
      tasks
      |> Enum.map(fn {_id, _name, task} -> task end)
      |> Task.yield_many(timeout)
      |> Enum.zip(tasks)
      |> Enum.map(fn {{_task_ref, result}, {tool_use_id, tool_name, task}} ->
        case result do
          {:ok, tool_result} ->
            {tool_use_id, tool_result}

          {:exit, reason} ->
            Logger.error(
              "#{session_prefix} Tool crashed: #{tool_name}, reason: #{inspect(reason)}"
            )

            {tool_use_id, {:error, "Tool crashed: #{inspect(reason)}"}}

          nil ->
            # Task timed out - kill it to prevent process leak
            Task.shutdown(task, :brutal_kill)
            {tool_use_id, {:error, "Tool execution timed out after #{timeout}ms"}}
        end
      end)

    results
  end

  # Execute a single tool call
  defp execute_tool(tool_use, context, tool_map) do
    case Map.get(tool_map, tool_use.name) do
      nil ->
        {:error, "Tool '#{tool_use.name}' not found"}

      tool_module ->
        result = tool_module.execute(tool_use.args, context)
        maybe_spill_to_cache(result, tool_use.name, tool_module, context)
    end
  rescue
    exception ->
      {:error, "Tool execution error: #{Exception.message(exception)}"}
  end

  # Check if result should be spilled to cache based on size threshold
  defp maybe_spill_to_cache({:ok, content_blocks} = result, tool_name, tool_module, context) do
    # Never spill use_skill results — the agent needs the full skill definition
    # in the system injection at agent.ex:1405-1413 (skills spec section 2.5)
    if tool_name == "use_skill" do
      result
      # Only spill if cache is available and configured
    else
      if context.cache_tid && context.cache_config do
        # Calculate total byte size of all content blocks
        total_bytes =
          Enum.reduce(content_blocks, 0, fn block, acc ->
            acc + content_block_byte_size(block)
          end)

        # Estimate tokens as byte_size / 4
        estimated_tokens = div(total_bytes, 4)

        # Get threshold for this tool (or default)
        threshold = Map.get(context.cache_config, tool_name, context.cache_config["default"])

        # Spill if exceeds threshold
        if estimated_tokens > threshold do
          spill_to_cache(result, content_blocks, tool_name, tool_module, context)
        else
          result
        end
      else
        result
      end
    end
  end

  defp maybe_spill_to_cache(result, _tool_name, _tool_module, _context), do: result

  # Calculate byte size of a content block
  defp content_block_byte_size(%{text: text}) when is_binary(text), do: byte_size(text)
  defp content_block_byte_size(_), do: 0

  # Spill result to cache and return summary
  defp spill_to_cache({:ok, content_blocks}, content_blocks, tool_name, tool_module, context) do
    # Generate cache key
    cache_key = generate_cache_key(tool_name)

    # Write full result to cache
    # Convert content blocks to a serializable format (just the text for now)
    cached_value = serialize_content_blocks(content_blocks)

    :ok =
      Store.write(
        {:via, Registry, {Deft.ProcessRegistry, {:cache, context.session_id, context.lead_id}}},
        cache_key,
        cached_value,
        %{tool: tool_name, created: System.monotonic_time()}
      )

    # Generate summary using tool's summarize callback or default
    summary_text =
      if function_exported?(tool_module, :summarize, 2) do
        tool_module.summarize(content_blocks, cache_key)
      else
        default_summary(content_blocks, cache_key)
      end

    # Return summary as new content blocks
    {:ok, [%Text{text: summary_text}]}
  rescue
    error ->
      # If caching fails, return original result (degraded but functional)
      require Logger
      Logger.warning("Failed to spill to cache: #{inspect(error)}")
      {:ok, content_blocks}
  end

  # Generate a cache key for a tool result
  defp generate_cache_key(tool_name) do
    # Use random hex string for uniqueness
    random_hex =
      :crypto.strong_rand_bytes(6)
      |> Base.encode16(case: :lower)

    "#{tool_name}-#{random_hex}"
  end

  # Serialize content blocks for cache storage
  defp serialize_content_blocks(content_blocks) do
    # For now, just extract and join all text
    content_blocks
    |> Enum.map(fn
      %{text: text} -> text
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  # Default summary when tool doesn't implement summarize/2
  defp default_summary(content_blocks, cache_key) do
    # Count total lines and characters
    text = serialize_content_blocks(content_blocks)
    line_count = length(String.split(text, "\n"))
    char_count = String.length(text)

    """
    Result cached (#{line_count} lines, #{char_count} chars).

    Full results: cache://#{cache_key}
    """
  end
end
