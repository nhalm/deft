defmodule DeftWeb.ChatLive do
  @moduledoc """
  Main chat interface LiveView.

  Displays real-time agent conversation with streaming output, tool execution,
  thinking blocks, and agent roster. Supports vim/tmux-style keybindings.
  """

  use Phoenix.LiveView

  alias Phoenix.HTML

  @impl true
  def mount(params, _session, socket) do
    # Get session_id from URL params (e.g., /?session=abc123)
    session_id = params["session"]

    if connected?(socket) do
      # Subscribe to agent events for this session
      Registry.register(Deft.Registry, {:session, session_id}, [])
      Registry.register(Deft.Registry, {:job_status, session_id}, [])
    end

    # Initialize all assigns
    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:messages, [])
      |> assign(:streaming_text, "")
      |> assign(:streaming_thinking, "")
      |> assign(:agent_state, :idle)
      |> assign(:input, "")
      |> assign(:active_tools, %{})
      |> assign(:tokens_input, 0)
      |> assign(:tokens_output, 0)
      |> assign(:cost, 0.0)
      |> assign(:turn_count, 0)
      |> assign(:turn_limit, 25)
      |> assign(:om_observation_count, 0)
      |> assign(:om_memory_tokens, 0)
      |> assign(:agent_statuses, [])
      |> assign(:job_active, false)
      |> assign(:vim_mode, :insert)
      |> assign(:scroll_offset, 0)
      |> assign(:tmux_prefix, false)
      |> assign(:roster_visible, false)
      |> assign(:repo_name, get_repo_name())
      |> assign(:agent_identity, "Solo")
      |> stream(:conversation, [])

    {:ok, socket}
  end

  @impl true
  def handle_info({:agent_event, {:text_delta, delta}}, socket) do
    {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> delta)}
  end

  def handle_info({:agent_event, {:thinking_delta, delta}}, socket) do
    {:noreply, assign(socket, :streaming_thinking, socket.assigns.streaming_thinking <> delta)}
  end

  def handle_info({:agent_event, {:tool_call_start, %{id: id, name: name}}}, socket) do
    tool = %{id: id, name: name, status: :running, duration: nil}
    active_tools = Map.put(socket.assigns.active_tools, id, tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info({:agent_event, {:tool_call_done, %{id: id} = tool_result}}, socket) do
    active_tools = socket.assigns.active_tools

    updated_tool =
      active_tools
      |> Map.get(id, %{})
      |> Map.merge(%{status: :done, duration: Map.get(tool_result, :duration)})

    active_tools = Map.put(active_tools, id, updated_tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info({:agent_event, {:state_change, state}}, socket) do
    {:noreply, assign(socket, :agent_state, state)}
  end

  def handle_info({:agent_event, {:usage, %{input: input_tokens, output: output_tokens}}}, socket) do
    socket =
      socket
      |> assign(:tokens_input, socket.assigns.tokens_input + input_tokens)
      |> assign(:tokens_output, socket.assigns.tokens_output + output_tokens)

    {:noreply, socket}
  end

  def handle_info({:agent_event, {:job_status, statuses}}, socket) do
    socket =
      socket
      |> assign(:agent_statuses, statuses)
      |> assign(:job_active, true)
      |> assign(:roster_visible, true)

    {:noreply, socket}
  end

  def handle_info({:agent_event, _other}, socket) do
    # Ignore unknown events
    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => _key}, socket) do
    # Placeholder for keydown handling (will be implemented in next work items)
    {:noreply, socket}
  end

  # Private helpers

  defp get_repo_name do
    case File.cwd() do
      {:ok, path} -> Path.basename(path)
      _ -> "unknown"
    end
  end

  defp mode_indicator(:normal), do: "[NOR]"
  defp mode_indicator(:insert), do: "[INS]"
  defp mode_indicator(:command), do: "[CMD]"

  defp render_conversation_item(item) do
    # Placeholder for rendering conversation items
    HTML.raw(item.content || "")
  end
end
