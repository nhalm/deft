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
      thinking = Map.get(config, :thinking, false)
      thinking_budget = Map.get(config, :thinking_budget, 4096)

      # Spawn a process to handle the streaming request
      # Use spawn instead of spawn_link so stream crashes don't kill the agent
      pid =
        spawn(fn ->
          stream_loop(
            caller,
            api_key,
            messages,
            tools,
            model,
            max_tokens,
            temperature,
            thinking,
            thinking_budget
          )
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
  defp stream_loop(
         caller,
         api_key,
         messages,
         tools,
         model,
         max_tokens,
         temperature,
         thinking,
         thinking_budget
       ) do
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
      |> maybe_add_thinking(thinking, thinking_budget)

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

    case event_type do
      "content_block_start" ->
        handle_content_block_start(caller, sse_event, tool_state)

      "content_block_delta" ->
        handle_content_block_delta(caller, sse_event, tool_state)

      "content_block_stop" ->
        handle_tool_call_stop(caller, sse_event, tool_state)

      _ ->
        # Other events don't need tool_state tracking
        handle_parsed_event(caller, parse_event(sse_event), tool_state)
    end
  end

  # Handle content_block_start events with index → real_id mapping for tool calls
  defp handle_content_block_start(caller, sse_event, tool_state) do
    data = Map.get(sse_event, :data, "")

    case Jason.decode(data) do
      {:ok,
       %{"content_block" => %{"type" => "tool_use", "id" => id, "name" => name}, "index" => idx}} ->
        # Store index mapping and initialize JSON buffer
        tool_state =
          tool_state
          |> Map.put({:idx, idx}, id)
          |> Map.put(id, "")

        send(caller, {:provider_event, %ToolCallStart{id: id, name: name}})
        tool_state

      _ ->
        # Text or thinking blocks - no tracking needed
        tool_state
    end
  end

  # Handle content_block_delta events with real ID lookup for tool calls
  defp handle_content_block_delta(caller, sse_event, tool_state) do
    data = Map.get(sse_event, :data, "")

    case Jason.decode(data) do
      {:ok,
       %{
         "delta" => %{"type" => "input_json_delta", "partial_json" => json_fragment},
         "index" => idx
       }} ->
        # Look up real ID from index
        case Map.get(tool_state, {:idx, idx}) do
          nil ->
            # No mapping found - shouldn't happen, but skip
            tool_state

          real_id ->
            # Emit delta with real ID and accumulate JSON
            send(caller, {:provider_event, %ToolCallDelta{id: real_id, delta: json_fragment}})
            current = Map.get(tool_state, real_id, "")
            Map.put(tool_state, real_id, current <> json_fragment)
        end

      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        send(caller, {:provider_event, %TextDelta{delta: text}})
        tool_state

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => text}}} ->
        send(caller, {:provider_event, %ThinkingDelta{delta: text}})
        tool_state

      _ ->
        tool_state
    end
  end

  # Handle events from parse_event/1
  defp handle_parsed_event(_caller, :skip, tool_state), do: tool_state

  defp handle_parsed_event(caller, %ToolCallStart{id: id} = event, tool_state) do
    send(caller, {:provider_event, event})
    Map.put(tool_state, id, "")
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
        handle_tool_call_stop_with_index(caller, idx, tool_state)

      _ ->
        tool_state
    end
  end

  # Handle tool call stop when we have an index
  defp handle_tool_call_stop_with_index(caller, idx, tool_state) do
    case Map.get(tool_state, {:idx, idx}) do
      nil ->
        # Not a tool call, just a regular content block stop
        tool_state

      real_id ->
        emit_tool_call_done_and_cleanup(caller, idx, real_id, tool_state)
    end
  end

  # Emit ToolCallDone event and clean up tool state
  defp emit_tool_call_done_and_cleanup(caller, idx, real_id, tool_state) do
    json_str = Map.get(tool_state, real_id)

    if json_str do
      # Parse accumulated JSON (or use empty map if parsing fails)
      args =
        case Jason.decode(json_str) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      send(caller, {:provider_event, %ToolCallDone{id: real_id, args: args}})

      # Clean up both the mapping and the JSON buffer
      tool_state
      |> Map.delete({:idx, idx})
      |> Map.delete(real_id)
    else
      tool_state
    end
  end

  @impl Deft.Provider
  def parse_event(sse_event) do
    event_type = Map.get(sse_event, :event, "message")
    data = Map.get(sse_event, :data, "")

    case event_type do
      "message_start" -> parse_message_start(data)
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

      {:ok, %{"delta" => %{"type" => "input_json_delta"}}} ->
        # Tool call deltas are handled by the stateful streaming layer
        # (handle_content_block_delta) which has access to the real tool call ID
        # from content_block_start. parse_event/1 is stateless and cannot
        # provide the correct ID, so these events must be skipped here.
        :skip

      _ ->
        :skip
    end
  end

  # Parse message_start events (input token usage)
  defp parse_message_start(data) do
    case Jason.decode(data) do
      {:ok, %{"message" => %{"usage" => %{"input_tokens" => input}}}} ->
        %Usage{input: input, output: 0}

      _ ->
        :skip
    end
  end

  # Parse message_delta events (output token usage)
  defp parse_message_delta(data) do
    case Jason.decode(data) do
      {:ok, %{"usage" => %{"output_tokens" => output}}} ->
        %Usage{input: 0, output: output}

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

  # Add thinking parameter to request body if enabled
  defp maybe_add_thinking(body, false, _budget), do: body

  defp maybe_add_thinking(body, true, budget) do
    Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})
  end

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
  def model_config(model_name) do
    case model_name do
      "claude-sonnet-4" ->
        %{
          context_window: 200_000,
          max_output: 16_000,
          input_price_per_mtok: 3.00,
          output_price_per_mtok: 15.00
        }

      "claude-opus-4" ->
        %{
          context_window: 200_000,
          max_output: 32_000,
          input_price_per_mtok: 15.00,
          output_price_per_mtok: 75.00
        }

      "claude-haiku-4.5" ->
        %{
          context_window: 200_000,
          max_output: 8192,
          input_price_per_mtok: 0.80,
          output_price_per_mtok: 4.00
        }

      _ ->
        {:error, :unknown_model}
    end
  end
end
