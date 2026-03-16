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
  defp stream_loop(caller, api_key, messages, tools, model, max_tokens, temperature) do
    # Format messages and tools for Anthropic API
    {system_param, wire_messages} = format_messages(messages)
    wire_tools = format_tools(tools)

    # Build request body
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        temperature: temperature,
        messages: wire_messages,
        stream: true
      }
      |> maybe_add_system(system_param)
      |> maybe_add_tools(wire_tools)

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
        new_tool_state = Enum.reduce(events, tool_state, &process_single_event(caller, &1, &2))
        {remaining, new_tool_state}
    end
  end

  # Process a single SSE event
  defp process_single_event(caller, sse_event, tool_state) do
    event_type = Map.get(sse_event, :event, "message")

    if event_type == "content_block_stop" do
      handle_tool_call_stop(caller, sse_event, tool_state)
    else
      handle_parsed_event(caller, parse_event(sse_event), tool_state)
    end
  end

  # Handle events from parse_event/1
  defp handle_parsed_event(_caller, :skip, tool_state), do: tool_state

  defp handle_parsed_event(caller, %ToolCallStart{id: id} = event, tool_state) do
    send(caller, {:provider_event, event})
    Map.put(tool_state, id, "")
  end

  defp handle_parsed_event(caller, %ToolCallDelta{id: id, delta: delta} = event, tool_state) do
    send(caller, {:provider_event, event})
    current = Map.get(tool_state, id, "")
    Map.put(tool_state, id, current <> delta)
  end

  defp handle_parsed_event(caller, event, tool_state) do
    send(caller, {:provider_event, event})
    tool_state
  end

  # Handle content_block_stop with accumulated tool state
  defp handle_tool_call_stop(caller, sse_event, tool_state) do
    data = Map.get(sse_event, :data, "")

    case Jason.decode(data) do
      {:ok, %{"index" => idx}} ->
        id = "tool_#{idx}"

        # Check if we have accumulated JSON for this tool call
        case Map.get(tool_state, id) do
          nil ->
            # Not a tool call, just a regular content block stop
            tool_state

          json_str ->
            # Parse accumulated JSON and emit ToolCallDone
            case Jason.decode(json_str) do
              {:ok, args} ->
                send(caller, {:provider_event, %ToolCallDone{id: id, args: args}})
                Map.delete(tool_state, id)

              {:error, _} ->
                # Send empty args if parsing failed
                send(caller, {:provider_event, %ToolCallDone{id: id, args: %{}}})
                Map.delete(tool_state, id)
            end
        end

      _ ->
        tool_state
    end
  end

  @impl Deft.Provider
  def parse_event(sse_event) do
    event_type = Map.get(sse_event, :event, "message")
    data = Map.get(sse_event, :data, "")

    case event_type do
      "content_block_start" -> parse_content_block_start(data)
      "content_block_delta" -> parse_content_block_delta(data)
      "message_delta" -> parse_message_delta(data)
      "message_stop" -> %Done{}
      "error" -> parse_error(data)
      # content_block_stop is handled separately in the streaming layer
      # because it requires accumulated state for tool calls
      _ -> :skip
    end
  end

  # Parse content_block_start events
  defp parse_content_block_start(data) do
    case Jason.decode(data) do
      {:ok, %{"content_block" => %{"type" => "text"}}} ->
        # Text blocks don't emit on start - first delta will be TextDelta
        :skip

      {:ok, %{"content_block" => %{"type" => "thinking"}}} ->
        # Thinking blocks don't emit on start - first delta will be ThinkingDelta
        :skip

      {:ok, %{"content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}} ->
        %ToolCallStart{id: id, name: name}

      _ ->
        :skip
    end
  end

  # Parse content_block_delta events
  defp parse_content_block_delta(data) do
    case Jason.decode(data) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        %TextDelta{delta: text}

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => text}}} ->
        %ThinkingDelta{delta: text}

      {:ok,
       %{
         "delta" => %{"type" => "input_json_delta", "partial_json" => json_fragment},
         "index" => idx
       }} ->
        # Anthropic uses index-based tracking for tool calls
        id = "tool_#{idx}"
        %ToolCallDelta{id: id, delta: json_fragment}

      _ ->
        :skip
    end
  end

  # Parse message_delta events (usage info)
  defp parse_message_delta(data) do
    case Jason.decode(data) do
      {:ok, %{"usage" => %{"input_tokens" => input, "output_tokens" => output}}} ->
        %Usage{input: input, output: output}

      _ ->
        :skip
    end
  end

  # Parse error events
  defp parse_error(data) do
    case Jason.decode(data) do
      {:ok, %{"error" => %{"message" => message}}} ->
        %Error{message: message}

      {:ok, %{"message" => message}} ->
        %Error{message: message}

      _ ->
        %Error{message: "Unknown error"}
    end
  end

  @impl Deft.Provider
  def format_messages(messages) do
    # Extract system messages and convert to system parameter
    {system_messages, other_messages} = Enum.split_with(messages, &(&1.role == :system))

    system_param = build_system_param(system_messages)

    # Convert user/assistant messages to wire format
    wire_messages =
      other_messages
      |> Enum.map(&message_to_wire/1)

    {system_param, wire_messages}
  end

  # Build the system parameter from system messages
  defp build_system_param([]), do: nil

  defp build_system_param(system_messages) do
    # Combine all system message content blocks
    all_content = Enum.flat_map(system_messages, & &1.content)

    # If all content is text, join into a single string
    if Enum.all?(all_content, &match?(%Deft.Message.Text{}, &1)) do
      all_content
      |> Enum.map(& &1.text)
      |> Enum.join("\n\n")
    else
      # Mixed content types - convert to wire format
      Enum.map(all_content, &content_block_to_wire/1)
    end
  end

  # Convert a message to wire format
  defp message_to_wire(message) do
    %{
      role: Atom.to_string(message.role),
      content: Enum.map(message.content, &content_block_to_wire/1)
    }
  end

  # Convert content blocks to wire format
  defp content_block_to_wire(%Deft.Message.Text{text: text}) do
    %{type: "text", text: text}
  end

  defp content_block_to_wire(%Deft.Message.ToolUse{id: id, name: name, args: args}) do
    %{type: "tool_use", id: id, name: name, input: args}
  end

  defp content_block_to_wire(%Deft.Message.ToolResult{
         tool_use_id: tool_use_id,
         content: content,
         is_error: is_error
       }) do
    %{type: "tool_result", tool_use_id: tool_use_id, content: content, is_error: is_error}
  end

  defp content_block_to_wire(%Deft.Message.Thinking{text: text}) do
    %{type: "thinking", thinking: text}
  end

  defp content_block_to_wire(%Deft.Message.Image{media_type: media_type, data: data}) do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: data
      }
    }
  end

  # Add system parameter to request body if present
  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :system, system)

  # Add tools to request body if present
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  @impl Deft.Provider
  def format_tools(tools) do
    Enum.map(tools, fn tool_module ->
      %{
        name: tool_module.name(),
        description: tool_module.description(),
        input_schema: tool_module.parameters()
      }
    end)
  end

  @impl Deft.Provider
  def model_config(_model_name) do
    # TODO: Implement in next work item
    {:error, :unknown_model}
  end
end
