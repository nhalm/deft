defmodule DeftWeb.ChatLive do
  @moduledoc """
  Main chat interface LiveView.

  Displays real-time agent conversation with streaming output, tool execution,
  thinking blocks, and agent roster. Supports vim/tmux-style keybindings.
  """

  use Phoenix.LiveView

  alias Deft.Session.Worker
  alias Deft.Skills.Registry, as: SkillsRegistry
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
      |> assign(:pending_g, false)
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

  def handle_info(
        {:agent_event, {:usage, %{input: input_tokens, output: output_tokens, cost: turn_cost}}},
        socket
      ) do
    socket =
      socket
      |> assign(:tokens_input, socket.assigns.tokens_input + input_tokens)
      |> assign(:tokens_output, socket.assigns.tokens_output + output_tokens)
      |> assign(:cost, socket.assigns.cost + turn_cost)

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
  def handle_event("submit", %{"input" => input}, socket) do
    # Clear input immediately for better UX
    socket = assign(socket, :input, "")

    # Trim whitespace
    input = String.trim(input)

    if input == "" do
      {:noreply, socket}
    else
      # Add user message to conversation
      socket = add_user_message(socket, input)

      # Dispatch command or send prompt
      socket =
        if String.starts_with?(input, "/") do
          handle_slash_command(socket, input)
        else
          send_prompt_to_agent(socket, input)
        end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("keydown", params, socket) do
    key = params["key"]
    ctrl = params["ctrlKey"] || false
    socket = handle_vim_key(socket, key, ctrl)
    {:noreply, socket}
  end

  # Private helpers

  defp handle_vim_key(socket, key, ctrl) do
    mode = socket.assigns.vim_mode
    pending_g = socket.assigns.pending_g

    case {mode, key, ctrl, pending_g} do
      # Escape always goes to normal mode and clears pending_g
      {_, "Escape", _, _} ->
        socket
        |> assign(:vim_mode, :normal)
        |> assign(:pending_g, false)

      # In normal mode: i or a enters insert mode
      {:normal, "i", false, _} ->
        socket
        |> assign(:vim_mode, :insert)
        |> assign(:pending_g, false)

      {:normal, "a", false, _} ->
        socket
        |> assign(:vim_mode, :insert)
        |> assign(:pending_g, false)

      # In normal mode: : or / enters command mode
      {:normal, ":", false, _} ->
        socket
        |> assign(:vim_mode, :command)
        |> assign(:pending_g, false)

      {:normal, "/", false, _} ->
        socket
        |> assign(:vim_mode, :command)
        |> assign(:pending_g, false)

      # Navigation keys in normal mode - delegate to scroll handler
      {:normal, key, ctrl, pending_g} when key in ["j", "k", "g", "G", "u", "d"] ->
        handle_scroll_key(socket, key, ctrl, pending_g)

      # Any other key in normal mode clears pending_g
      {:normal, _, _, true} ->
        assign(socket, :pending_g, false)

      # All other keys: no change
      _ ->
        socket
    end
  end

  defp handle_scroll_key(socket, key, ctrl, pending_g) do
    case {key, ctrl, pending_g} do
      # j - scroll down
      {"j", false, _} ->
        socket
        |> assign(:scroll_offset, socket.assigns.scroll_offset + 1)
        |> assign(:pending_g, false)

      # k - scroll up
      {"k", false, _} ->
        socket
        |> assign(:scroll_offset, max(0, socket.assigns.scroll_offset - 1))
        |> assign(:pending_g, false)

      # G - scroll to bottom
      {"G", false, _} ->
        socket
        |> assign(:scroll_offset, :bottom)
        |> assign(:pending_g, false)

      # g - first press sets pending_g, second press (gg) scrolls to top
      {"g", false, false} ->
        assign(socket, :pending_g, true)

      {"g", false, true} ->
        socket
        |> assign(:scroll_offset, 0)
        |> assign(:pending_g, false)

      # Ctrl+u - half-page scroll up
      {"u", true, _} ->
        socket
        |> assign(:scroll_offset, max(0, socket.assigns.scroll_offset - 10))
        |> assign(:pending_g, false)

      # Ctrl+d - half-page scroll down
      {"d", true, _} ->
        socket
        |> assign(:scroll_offset, socket.assigns.scroll_offset + 10)
        |> assign(:pending_g, false)

      # Other keys clear pending_g
      _ ->
        assign(socket, :pending_g, false)
    end
  end

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

  defp add_user_message(socket, text) do
    # Add user message to conversation stream
    message = %{id: System.unique_integer([:positive, :monotonic]), role: :user, content: text}
    stream_insert(socket, :conversation, message)
  end

  defp send_prompt_to_agent(socket, text) do
    agent = Worker.agent_via_tuple(socket.assigns.session_id)
    Deft.Agent.prompt(agent, text)
    socket
  end

  defp handle_slash_command(socket, input) do
    # Parse command and args (e.g., "/model gpt-4" -> {"model", "gpt-4"})
    [command | args] = String.split(input, " ", parts: 2)
    command = String.trim_leading(command, "/")
    args = if args == [], do: "", else: List.first(args)

    case command do
      "help" ->
        handle_help_command(socket)

      "clear" ->
        handle_clear_command(socket)

      "quit" ->
        handle_quit_command(socket)

      _ ->
        # Dispatch to Skills Registry
        dispatch_skill_or_command(socket, command, args)
    end
  end

  defp handle_help_command(socket) do
    # Display help message in conversation
    help_text = """
    Available commands:
    /help - Show this help message
    /clear - Clear conversation display
    /quit - Stop server and exit
    /model <name> - Switch model
    /cost - Show cost breakdown
    /status - Show job status
    /observations - Show OM observations
    /forget <text> - Mark observation for removal
    /correct <old> -> <new> - Mark observation for correction
    /inspect <lead> - Show Lead's Site Log entries
    /plan - Re-display approved plan
    /compact - Force compaction

    Keybindings:
    Esc - Switch to normal mode
    i/a - Enter insert mode (in normal mode)
    j/k - Scroll up/down (in normal mode)
    Ctrl+b then % - Toggle roster panel
    """

    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :system,
      content: help_text
    }

    stream_insert(socket, :conversation, message)
  end

  defp handle_clear_command(socket) do
    # Clear conversation display (reset stream)
    assign(socket, :messages, [])
    |> stream(:conversation, [], reset: true)
  end

  defp handle_quit_command(socket) do
    # Stop the server
    # For now, just display a message. Actual shutdown will be handled elsewhere.
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :system,
      content: "Shutting down..."
    }

    socket
    |> stream_insert(:conversation, message)
    |> push_event("shutdown", %{})
  end

  defp dispatch_skill_or_command(socket, command_name, _args) do
    case SkillsRegistry.lookup(command_name) do
      :not_found ->
        # Unknown command
        message = %{
          id: System.unique_integer([:positive, :monotonic]),
          role: :system,
          content: "Unknown command: /#{command_name}. Type /help for available commands."
        }

        stream_insert(socket, :conversation, message)

      _entry ->
        # Load and inject the skill/command
        case SkillsRegistry.load_definition(command_name) do
          {:ok, definition} ->
            agent = Worker.agent_via_tuple(socket.assigns.session_id)
            Deft.Agent.inject_skill(agent, definition)
            socket

          {:error, reason} ->
            message = %{
              id: System.unique_integer([:positive, :monotonic]),
              role: :system,
              content: "Failed to load command #{command_name}: #{inspect(reason)}"
            }

            stream_insert(socket, :conversation, message)
        end
    end
  end
end
