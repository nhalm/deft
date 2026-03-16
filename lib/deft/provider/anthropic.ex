defmodule Deft.Provider.Anthropic do
  @moduledoc """
  Anthropic Messages API provider implementation.

  Implements the Deft.Provider behaviour for Anthropic's Claude models.
  Handles streaming requests to the Messages API, SSE parsing, and event
  normalization.
  """

  @behaviour Deft.Provider

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

  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @doc """
  Initiates a streaming request to Anthropic's Messages API.

  Spawns a process that manages the HTTP connection and sends parsed events
  to the caller's mailbox as `{:provider_event, event}` messages.

  ## Environment

  Requires `ANTHROPIC_API_KEY` environment variable. Fails fast if missing.

  ## Returns

  - `{:ok, stream_ref}` - Stream started successfully. The stream_ref is a PID
    that can be used to cancel the stream.
  - `{:error, reason}` - Failed to start stream (missing API key, network error, etc.)
  """
  @impl Deft.Provider
  def stream(messages, tools, config) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      caller = self()
      model = Map.get(config, :model, "claude-sonnet-4")
      max_tokens = Map.get(config, :max_tokens, 8192)
      temperature = Map.get(config, :temperature, 1.0)

      # Spawn a process to handle the streaming request
      pid =
        spawn_link(fn ->
          stream_loop(caller, api_key, messages, tools, model, max_tokens, temperature)
        end)

      {:ok, pid}
    end
  end

  @doc """
  Cancels an in-flight streaming request.

  Terminates the stream process, which closes the HTTP connection.
  Idempotent - safe to call multiple times.
  """
  @impl Deft.Provider
  def cancel_stream(stream_ref) when is_pid(stream_ref) do
    Process.exit(stream_ref, :cancelled)
    :ok
  end

  # Private streaming loop
  defp stream_loop(caller, api_key, _messages, _tools, model, max_tokens, temperature) do
    # Build request body
    body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [
        %{
          role: "user",
          content: "Hello"
        }
      ],
      stream: true
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    # Start streaming request
    case Req.post(@api_url,
           json: body,
           headers: headers,
           into: :self,
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{} = response} ->
        # Start receiving chunks with SSE parser state
        receive_chunks(caller, response.body, "", %{})

      {:error, reason} ->
        send(
          caller,
          {:provider_event, %Error{message: "HTTP request failed: #{inspect(reason)}"}}
        )
    end
  end

  # Receive and process streaming chunks with SSE buffering
  defp receive_chunks(caller, req_stream, buffer, tool_state) do
    receive do
      {^req_stream, {:data, chunk}} ->
        # Append to buffer and process complete SSE events
        new_buffer = buffer <> chunk
        {remaining_buffer, new_tool_state} = process_sse_buffer(caller, new_buffer, tool_state)
        receive_chunks(caller, req_stream, remaining_buffer, new_tool_state)

      {^req_stream, :done} ->
        send(caller, {:provider_event, %Done{}})

      {^req_stream, {:error, reason}} ->
        send(caller, {:provider_event, %Error{message: "Stream error: #{inspect(reason)}"}})
    after
      120_000 ->
        send(caller, {:provider_event, %Error{message: "Stream timeout"}})
    end
  end

  # Process SSE buffer and extract complete events
  defp process_sse_buffer(caller, buffer, tool_state) do
    case ServerSentEvents.parse(buffer) do
      {events, remaining} ->
        # Process each event
        new_tool_state =
          Enum.reduce(events, tool_state, fn event, acc ->
            process_sse_event(caller, event, acc)
          end)

        {remaining, new_tool_state}
    end
  end

  # Process a single SSE event (event is a map with :event, :data, :id, :retry keys)
  defp process_sse_event(caller, event, tool_state) do
    event_type = Map.get(event, :event, "message")
    data = Map.get(event, :data, "")
    route_event(event_type, caller, data, tool_state)
  end

  # Route event to appropriate handler
  defp route_event("message_start", _caller, _data, tool_state), do: tool_state
  defp route_event("message_stop", _caller, _data, tool_state), do: tool_state
  defp route_event("ping", _caller, _data, tool_state), do: tool_state

  defp route_event("content_block_start", caller, data, tool_state),
    do: handle_content_block_start(caller, data, tool_state)

  defp route_event("content_block_delta", caller, data, tool_state),
    do: handle_content_block_delta(caller, data, tool_state)

  defp route_event("content_block_stop", caller, data, tool_state),
    do: handle_content_block_stop(caller, data, tool_state)

  defp route_event("message_delta", caller, data, tool_state),
    do: handle_message_delta(caller, data, tool_state)

  defp route_event("error", caller, data, tool_state) do
    handle_error_event(caller, data)
    tool_state
  end

  defp route_event(event_type, _caller, _data, tool_state) do
    Logger.debug("Ignoring unknown SSE event type: #{event_type}")
    tool_state
  end

  # Handle content_block_start event
  defp handle_content_block_start(caller, data, tool_state) do
    case Jason.decode(data) do
      {:ok, %{"content_block" => %{"type" => "text"}} = _block} ->
        # First text chunk will come in delta
        tool_state

      {:ok, %{"content_block" => %{"type" => "thinking"}} = _block} ->
        # First thinking chunk will come in delta
        tool_state

      {:ok, %{"content_block" => %{"type" => "tool_use", "id" => id, "name" => name}} = _block} ->
        send(caller, {:provider_event, %ToolCallStart{id: id, name: name}})
        # Initialize tool call buffer
        Map.put(tool_state, id, "")

      _ ->
        tool_state
    end
  end

  # Handle content_block_delta event
  defp handle_content_block_delta(caller, data, tool_state) do
    case Jason.decode(data) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        send(caller, {:provider_event, %TextDelta{delta: text}})
        tool_state

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => text}}} ->
        send(caller, {:provider_event, %ThinkingDelta{delta: text}})
        tool_state

      {:ok,
       %{
         "delta" => %{"type" => "input_json_delta", "partial_json" => json_fragment},
         "index" => idx
       }} ->
        # Need to track by tool call ID, but Anthropic uses index
        # We'll use a synthesized ID based on index
        id = "tool_#{idx}"
        send(caller, {:provider_event, %ToolCallDelta{id: id, delta: json_fragment}})
        # Accumulate the JSON
        current = Map.get(tool_state, id, "")
        Map.put(tool_state, id, current <> json_fragment)

      _ ->
        tool_state
    end
  end

  # Handle content_block_stop event
  defp handle_content_block_stop(caller, data, tool_state) do
    case Jason.decode(data) do
      {:ok, %{"index" => idx}} ->
        # Parse accumulated JSON for this tool call
        id = "tool_#{idx}"
        json_str = Map.get(tool_state, id, "{}")

        case Jason.decode(json_str) do
          {:ok, args} ->
            send(caller, {:provider_event, %ToolCallDone{id: id, args: args}})
            Map.delete(tool_state, id)

          {:error, _} ->
            # Send empty args if parsing failed
            send(caller, {:provider_event, %ToolCallDone{id: id, args: %{}}})
            Map.delete(tool_state, id)
        end

      _ ->
        tool_state
    end
  end

  # Handle message_delta event (usage info)
  defp handle_message_delta(caller, data, tool_state) do
    case Jason.decode(data) do
      {:ok, %{"usage" => %{"input_tokens" => input, "output_tokens" => output}}} ->
        send(caller, {:provider_event, %Usage{input: input, output: output}})
        tool_state

      _ ->
        tool_state
    end
  end

  # Handle error event
  defp handle_error_event(caller, data) do
    case Jason.decode(data) do
      {:ok, %{"error" => %{"message" => message}}} ->
        send(caller, {:provider_event, %Error{message: message}})

      {:ok, %{"message" => message}} ->
        send(caller, {:provider_event, %Error{message: message}})

      _ ->
        send(caller, {:provider_event, %Error{message: "Unknown error"}})
    end
  end

  @impl Deft.Provider
  def parse_event(_raw_event) do
    # TODO: Implement in next work item
    :skip
  end

  @impl Deft.Provider
  def format_messages(_messages) do
    # TODO: Implement in next work item
    []
  end

  @impl Deft.Provider
  def format_tools(_tools) do
    # TODO: Implement in next work item
    []
  end

  @impl Deft.Provider
  def model_config(_model_name) do
    # TODO: Implement in next work item
    {:error, :unknown_model}
  end
end
