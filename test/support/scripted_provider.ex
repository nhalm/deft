defmodule Deft.ScriptedProvider do
  @moduledoc """
  Test provider that returns pre-defined responses in sequence.

  Implements the Deft.Provider behaviour for integration testing without real
  LLM calls. Responses are scripted in advance and consumed one per stream/3 call.

  ## Example

      {:ok, pid} = ScriptedProvider.start_link(responses: [
        %{text: "I'll research the codebase.", tool_calls: [%{name: "grep", args: %{...}}]},
        %{text: "Based on my research, here's the plan.", tool_calls: []},
      ])

      # Use as provider in agent config
      Deft.Agent.start_link(provider_module: Deft.ScriptedProvider, provider_pid: pid, ...)

  ## Response Format

  Each scripted response can include:
  - `text` — assistant text content (required)
  - `tool_calls` — list of tool call blocks with `name` and `args` (default: [])
  - `thinking` — optional thinking block content
  - `usage` — optional token usage map with `input` and `output` keys
  - `delay_ms` — optional delay before responding (for timeout tests)
  - `error` — optional error message to return instead of a response (for retry tests)

  ## Assertions

  - `ScriptedProvider.calls(pid)` returns list of `{messages, tools, config}` tuples
  - `ScriptedProvider.assert_called(pid, n)` asserts exactly `n` calls were made
  - `ScriptedProvider.assert_exhausted(pid)` asserts all responses were consumed
  """

  use GenServer

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
    ToolCallDone,
    Usage,
    Done
  }

  @behaviour Deft.Provider

  # Client API

  @doc """
  Starts the ScriptedProvider GenServer.

  ## Options

  - `:responses` - Ordered list of scripted responses (required)
  """
  def start_link(opts) do
    responses = Keyword.fetch!(opts, :responses)
    GenServer.start_link(__MODULE__, responses)
  end

  @doc """
  Returns the list of calls made to stream/3.

  Each call is represented as a `{messages, tools, config}` tuple.
  """
  def calls(pid) do
    GenServer.call(pid, :get_calls)
  end

  @doc """
  Asserts that exactly `n` calls were made to stream/3.

  Raises if the assertion fails.
  """
  def assert_called(pid, n) do
    actual = length(calls(pid))

    if actual != n do
      raise "Expected #{n} calls to ScriptedProvider.stream/3, got #{actual}"
    end

    :ok
  end

  @doc """
  Asserts that all scripted responses were consumed.

  Raises if there are unconsumed responses remaining.
  """
  def assert_exhausted(pid) do
    case GenServer.call(pid, :check_exhausted) do
      :ok ->
        :ok

      {:error, remaining} ->
        raise "ScriptedProvider has #{remaining} unconsumed response(s)"
    end
  end

  # Provider behaviour implementation

  @impl Deft.Provider
  def stream(messages, tools, config) do
    # Extract provider_pid from config
    provider_pid = Map.get(config, :provider_pid)

    if is_nil(provider_pid) do
      {:error, :missing_provider_pid}
    else
      GenServer.call(provider_pid, {:stream, messages, tools, config})
    end
  end

  @impl Deft.Provider
  def cancel_stream(stream_ref) when is_pid(stream_ref) do
    Process.exit(stream_ref, :cancelled)
    :ok
  end

  @impl Deft.Provider
  def parse_event(_sse_event) do
    # ScriptedProvider doesn't use SSE parsing - events are already normalized
    :skip
  end

  @impl Deft.Provider
  def format_messages(messages) do
    # Pass through - not needed for scripted responses
    messages
  end

  @impl Deft.Provider
  def format_tools(tools) do
    # Pass through - not needed for scripted responses
    tools
  end

  @impl Deft.Provider
  def model_config(_model_name) do
    %{
      context_window: 200_000,
      max_output: 8192,
      input_price_per_mtok: 0.0,
      output_price_per_mtok: 0.0
    }
  end

  # GenServer callbacks

  @impl GenServer
  def init(responses) do
    {:ok, %{responses: responses, calls: []}}
  end

  @impl GenServer
  def handle_call({:stream, messages, tools, config}, from, state) do
    # Record the call
    new_calls = state.calls ++ [{messages, tools, config}]

    case state.responses do
      [] ->
        # No more responses - return error
        {:reply, {:error, :no_more_responses}, %{state | calls: new_calls}}

      [response | remaining_responses] ->
        handle_response(response, from, new_calls, remaining_responses, state)
    end
  end

  @impl GenServer
  def handle_call(:get_calls, _from, state) do
    {:reply, state.calls, state}
  end

  @impl GenServer
  def handle_call(:check_exhausted, _from, state) do
    if state.responses == [] do
      {:reply, :ok, state}
    else
      {:reply, {:error, length(state.responses)}, state}
    end
  end

  # Private helpers

  defp handle_response(%{error: error}, _from, new_calls, remaining_responses, state) do
    # Return error without spawning stream
    {:reply, {:error, error}, %{state | calls: new_calls, responses: remaining_responses}}
  end

  defp handle_response(response, from, new_calls, remaining_responses, state) do
    # Spawn stream process and return stream ref
    # Extract caller PID from the from tuple {pid, ref}
    {caller_pid, _ref} = from
    stream_pid = spawn(fn -> emit_response(caller_pid, response) end)

    {:reply, {:ok, stream_pid}, %{state | calls: new_calls, responses: remaining_responses}}
  end

  defp emit_response(caller, response) do
    # Apply delay if specified
    if delay = Map.get(response, :delay_ms) do
      Process.sleep(delay)
    end

    # Emit thinking if present
    if thinking = Map.get(response, :thinking) do
      emit_thinking_chunks(caller, thinking)
    end

    # Emit tool calls if present
    tool_calls = Map.get(response, :tool_calls, [])

    Enum.each(tool_calls, fn tool_call ->
      emit_tool_call(caller, tool_call)
    end)

    # Emit text if present
    if text = Map.get(response, :text) do
      emit_text_chunks(caller, text)
    end

    # Emit usage if present
    if usage = Map.get(response, :usage) do
      input = Map.get(usage, :input, 0)
      output = Map.get(usage, :output, 0)
      send(caller, {:provider_event, %Usage{input: input, output: output}})
    end

    # Emit done event
    send(caller, {:provider_event, %Done{}})
  end

  defp emit_thinking_chunks(caller, thinking) do
    # Split into chunks at word boundaries
    words = String.split(thinking, ~r/\s+/, include_captures: true)

    Enum.each(words, fn word ->
      send(caller, {:provider_event, %ThinkingDelta{delta: word}})
    end)
  end

  defp emit_text_chunks(caller, text) do
    # Split into chunks at word boundaries
    words = String.split(text, ~r/\s+/, include_captures: true)

    Enum.each(words, fn word ->
      send(caller, {:provider_event, %TextDelta{delta: word}})
    end)
  end

  defp emit_tool_call(caller, tool_call) do
    name = Map.fetch!(tool_call, :name)
    args = Map.fetch!(tool_call, :args)
    id = Map.get(tool_call, :id, generate_tool_call_id())

    # Emit tool call start
    send(caller, {:provider_event, %ToolCallStart{id: id, name: name}})

    # Emit tool call args as JSON deltas
    json = Jason.encode!(args)
    # Split JSON into small chunks to simulate streaming
    chunks = chunk_json(json)

    Enum.each(chunks, fn chunk ->
      send(caller, {:provider_event, %ToolCallDelta{id: id, delta: chunk}})
    end)

    # Emit tool call done with parsed args
    send(caller, {:provider_event, %ToolCallDone{id: id, args: args}})
  end

  defp chunk_json(json) do
    # Split JSON string into chunks of ~20 characters at safe boundaries
    # This simulates realistic streaming without breaking JSON structure
    # For simplicity, we'll just chunk by characters
    chunk_size = 20
    json |> String.graphemes() |> Enum.chunk_every(chunk_size) |> Enum.map(&Enum.join/1)
  end

  defp generate_tool_call_id do
    "toolu_scripted_#{:erlang.unique_integer([:positive])}"
  end
end
