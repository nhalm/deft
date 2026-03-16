defmodule Deft.Agent.ToolRunner do
  @moduledoc """
  Task.Supervisor for executing tool calls concurrently.

  Tool execution is supervised and isolated from the agent process. Each tool
  call is executed in its own task via `async_nolink`, and results are collected
  with timeouts via `Task.yield_many/2`.

  Exceptions in tool execution are caught and converted to error results.
  """

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
  - `timeout` — Timeout in milliseconds for each tool (default: 120_000)

  ## Returns

  List of `{tool_use_id, result}` tuples in the same order as tool_calls.
  """
  def execute_batch(supervisor, tool_calls, context, timeout \\ 120_000) do
    # Spawn async tasks for each tool call
    tasks =
      Enum.map(tool_calls, fn tool_use ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            execute_tool(tool_use, context)
          end)

        {tool_use.id, task}
      end)

    # Collect results with timeout
    results =
      tasks
      |> Enum.map(fn {_id, task} -> task end)
      |> Task.yield_many(timeout)
      |> Enum.zip(tasks)
      |> Enum.map(fn {{_task_ref, result}, {tool_use_id, _task_struct}} ->
        case result do
          {:ok, tool_result} ->
            {tool_use_id, tool_result}

          {:exit, reason} ->
            {tool_use_id, {:error, "Tool crashed: #{inspect(reason)}"}}

          nil ->
            # Task timed out
            {tool_use_id, {:error, "Tool execution timed out after #{timeout}ms"}}
        end
      end)

    results
  end

  # Execute a single tool call
  defp execute_tool(tool_use, _context) do
    # For now, since no tools are implemented yet, return an error
    # Future work items will implement tools and register them
    {:error, "Tool '#{tool_use.name}' not found"}
  rescue
    exception ->
      {:error, "Tool execution error: #{Exception.message(exception)}"}
  end
end
