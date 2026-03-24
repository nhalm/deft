defmodule DeftWeb.ChatLive do
  @moduledoc """
  Main chat interface LiveView.

  Displays real-time agent conversation with streaming output, tool execution,
  thinking blocks, and agent roster. Supports vim/tmux-style keybindings.
  """

  use DeftWeb, :live_view

  alias Deft.Session.Worker
  alias Deft.Skills.Registry, as: SkillsRegistry

  import DeftWeb.Components.Thinking
  import DeftWeb.Components.ToolCall
  import DeftWeb.Components.StatusBar
  import DeftWeb.Components.Roster

  @impl true
  def mount(params, _session, socket) do
    # Get session_id from URL params (e.g., /?session=abc123)
    session_id = params["session"]

    # Redirect to session picker if no session_id provided
    # (direct visit to /, session picker q key, /quit redirect)
    if is_nil(session_id) do
      {:ok, push_navigate(socket, to: "/sessions")}
    else
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
        |> assign(:tools_expanded, %{})
        |> assign(:tokens_input, 0)
        |> assign(:tokens_output, 0)
        |> assign(:cost, 0.0)
        |> assign(:turn_count, 0)
        |> assign(:turn_limit, 25)
        |> assign(:om_observation_count, 0)
        |> assign(:om_memory_tokens, 0)
        |> assign(:agent_statuses, [])
        |> assign(:job_active, false)
        |> assign(:job_budget, 10.0)
        |> assign(:job_started_at, nil)
        |> assign(:vim_mode, :insert)
        |> assign(:scroll_offset, 0)
        |> assign(:pending_g, false)
        |> assign(:tmux_prefix, false)
        |> assign(:roster_visible, false)
        |> assign(:zoom, false)
        |> assign(:active_pane, :left)
        |> assign(:repo_name, get_repo_name())
        |> assign(:agent_identity, "Solo")
        |> assign(:thinking_blocks_expanded, %{})
        |> assign(:last_ctrl_c, nil)
        |> assign(:input_history, [])
        |> assign(:input_history_index, nil)
        |> assign(:turn_limit_reached, false)
        |> assign(:turn_limit_count, 0)
        |> assign(:turn_limit_max, 0)
        |> stream(:conversation, [])

      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:agent_event, {:text_delta, delta}}, socket) do
    {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> delta)}
  end

  def handle_info({:agent_event, {:thinking_delta, delta}}, socket) do
    {:noreply, assign(socket, :streaming_thinking, socket.assigns.streaming_thinking <> delta)}
  end

  def handle_info({:agent_event, {:tool_call_start, %{id: id, name: name}}}, socket) do
    tool = %{id: id, name: name, status: :running, duration: nil, input: nil, output: nil}
    active_tools = Map.put(socket.assigns.active_tools, id, tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info({:agent_event, {:tool_call_done, %{id: id, args: args}}}, socket) do
    active_tools = socket.assigns.active_tools

    updated_tool =
      active_tools
      |> Map.get(id, %{})
      |> Map.put(:input, Jason.encode!(args, pretty: true))

    active_tools = Map.put(active_tools, id, updated_tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info(
        {:agent_event,
         {:tool_execution_complete,
          %{id: id, success: success, duration: duration_ms, result: result}}},
        socket
      ) do
    active_tools = socket.assigns.active_tools

    # Format the result for display
    output = format_tool_result(result)
    status = if success, do: :success, else: :error
    duration_sec = duration_ms / 1000.0

    updated_tool =
      active_tools
      |> Map.get(id, %{})
      |> Map.merge(%{status: status, duration: duration_sec, output: output})

    active_tools = Map.put(active_tools, id, updated_tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info({:agent_event, {:state_change, state}}, socket) do
    socket =
      if state == :idle do
        # Flush streaming content to conversation stream when turn ends
        thinking = socket.assigns.streaming_thinking
        text = socket.assigns.streaming_text

        socket =
          if thinking != "" or text != "" do
            # Build content: thinking first (with label), then text
            content_parts =
              [
                if(thinking != "", do: "[thinking: #{thinking}]", else: nil),
                if(text != "", do: text, else: nil)
              ]
              |> Enum.reject(&is_nil/1)

            content = Enum.join(content_parts, "\n\n")

            message = %{
              id: System.unique_integer([:positive, :monotonic]),
              role: :assistant,
              content: content
            }

            stream_insert(socket, :conversation, message)
          else
            socket
          end

        # Reset streaming buffers, clear active tools, and update state
        socket
        |> assign(:streaming_text, "")
        |> assign(:streaming_thinking, "")
        |> assign(:active_tools, %{})
        |> assign(:agent_state, state)
      else
        assign(socket, :agent_state, state)
      end

    {:noreply, socket}
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
      |> assign(:turn_count, socket.assigns.turn_count + 1)

    {:noreply, socket}
  end

  def handle_info({:agent_event, {:job_status, statuses}}, socket) do
    # Set job_started_at on first job_status event if not already set
    job_started_at =
      if socket.assigns.job_started_at == nil do
        System.system_time(:second)
      else
        socket.assigns.job_started_at
      end

    socket =
      socket
      |> assign(:agent_statuses, statuses)
      |> assign(:job_active, true)
      |> assign(:roster_visible, true)
      |> assign(:job_started_at, job_started_at)

    {:noreply, socket}
  end

  def handle_info({:agent_event, {:error, reason}}, socket) do
    # Display error message in conversation stream
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :error,
      content: "Error: #{inspect(reason)}"
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  def handle_info({:agent_event, {:turn_limit_reached, count, max}}, socket) do
    # Display turn limit message and prompt user to continue or abort
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :system,
      content: "Turn limit reached (#{count}/#{max})"
    }

    socket =
      socket
      |> stream_insert(:conversation, message)
      |> assign(:turn_limit_reached, true)
      |> assign(:turn_limit_count, count)
      |> assign(:turn_limit_max, max)

    {:noreply, socket}
  end

  def handle_info({:agent_event, _other}, socket) do
    # Ignore unknown events
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit", %{"input" => input}, socket) do
    # Trim whitespace
    input = String.trim(input)

    if input == "" do
      {:noreply, socket}
    else
      # Add to input history (newest first)
      history = [input | socket.assigns.input_history]

      # Clear input and reset history index
      socket =
        socket
        |> assign(:input, "")
        |> assign(:input_history, history)
        |> assign(:input_history_index, nil)

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

  @impl true
  def handle_event("toggle_thinking", %{"id" => id}, socket) do
    current_state = Map.get(socket.assigns.thinking_blocks_expanded, id, true)
    new_expanded_state = Map.put(socket.assigns.thinking_blocks_expanded, id, not current_state)
    {:noreply, assign(socket, :thinking_blocks_expanded, new_expanded_state)}
  end

  @impl true
  def handle_event("toggle_tool", %{"id" => id}, socket) do
    current_state = Map.get(socket.assigns.tools_expanded, id, false)
    new_expanded_state = Map.put(socket.assigns.tools_expanded, id, not current_state)
    {:noreply, assign(socket, :tools_expanded, new_expanded_state)}
  end

  @impl true
  def handle_event("continue_turn", _params, socket) do
    # Call continue_turn with true to allow the agent to proceed
    agent = Worker.agent_via_tuple(socket.assigns.session_id)
    Deft.Agent.continue_turn(agent, true)

    # Clear the turn limit reached state
    socket =
      socket
      |> assign(:turn_limit_reached, false)
      |> assign(:turn_limit_count, 0)
      |> assign(:turn_limit_max, 0)

    # Add a system message confirming the action
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :system,
      content: "Continuing turn..."
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  @impl true
  def handle_event("abort_turn", _params, socket) do
    # Call continue_turn with false to decline continuing
    agent = Worker.agent_via_tuple(socket.assigns.session_id)
    Deft.Agent.continue_turn(agent, false)

    # Clear the turn limit reached state
    socket =
      socket
      |> assign(:turn_limit_reached, false)
      |> assign(:turn_limit_count, 0)
      |> assign(:turn_limit_max, 0)

    # Add a system message confirming the action
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      role: :system,
      content: "Declining to continue turn..."
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  # Private helpers

  defp handle_vim_key(socket, key, ctrl) do
    tmux_prefix = socket.assigns.tmux_prefix

    # If tmux prefix is active, dispatch to tmux handler
    if tmux_prefix do
      handle_tmux_key(socket, key)
    else
      handle_standard_vim_key(socket, key, ctrl)
    end
  end

  # Ctrl+b sets tmux prefix
  defp handle_standard_vim_key(socket, "b", true) do
    assign(socket, :tmux_prefix, true)
  end

  # Ctrl+c aborts agent operation (single press) or force aborts (double press)
  defp handle_standard_vim_key(socket, "c", true) do
    now = System.monotonic_time(:millisecond)
    last_ctrl_c = socket.assigns.last_ctrl_c

    # Check if this is a double press (within 500ms)
    is_double_press = last_ctrl_c != nil and now - last_ctrl_c < 500

    if is_double_press do
      # Force abort (double Ctrl+c)
      # TODO: Implement force_abort when available in Agent module
      agent = Worker.agent_via_tuple(socket.assigns.session_id)
      Deft.Agent.abort(agent)

      message = %{
        id: System.unique_integer([:positive, :monotonic]),
        role: :system,
        content: "Force aborting agent operation..."
      }

      socket
      |> assign(:last_ctrl_c, nil)
      |> stream_insert(:conversation, message)
    else
      # First Ctrl+c - abort current operation
      agent = Worker.agent_via_tuple(socket.assigns.session_id)
      Deft.Agent.abort(agent)

      message = %{
        id: System.unique_integer([:positive, :monotonic]),
        role: :system,
        content: "Aborting agent operation... (press Ctrl+c again to force abort)"
      }

      socket
      |> assign(:last_ctrl_c, now)
      |> stream_insert(:conversation, message)
    end
  end

  # Ctrl+l clears/redraws the display
  defp handle_standard_vim_key(socket, "l", true) do
    # Clear conversation display
    socket
    |> assign(:messages, [])
    |> stream(:conversation, [], reset: true)
  end

  # Escape always goes to normal mode and clears pending_g
  defp handle_standard_vim_key(socket, "Escape", _ctrl) do
    socket
    |> assign(:vim_mode, :normal)
    |> assign(:pending_g, false)
  end

  # Mode change keys in normal mode
  defp handle_standard_vim_key(socket, key, false) when key in ["i", "a", ":", "/"] do
    if socket.assigns.vim_mode == :normal do
      handle_mode_change(socket, key)
    else
      socket
    end
  end

  # Navigation keys in normal mode
  defp handle_standard_vim_key(socket, key, ctrl) when key in ["j", "k", "g", "G", "u", "d"] do
    if socket.assigns.vim_mode == :normal do
      handle_scroll_key(socket, key, ctrl, socket.assigns.pending_g)
    else
      socket
    end
  end

  # Input history navigation in normal mode (Up/Down arrow keys)
  defp handle_standard_vim_key(socket, key, false) when key in ["ArrowUp", "ArrowDown"] do
    if socket.assigns.vim_mode == :normal do
      handle_history_navigation(socket, key)
    else
      socket
    end
  end

  # Any other key in normal mode with pending_g clears it
  defp handle_standard_vim_key(socket, _key, _ctrl) do
    if socket.assigns.vim_mode == :normal and socket.assigns.pending_g do
      assign(socket, :pending_g, false)
    else
      socket
    end
  end

  defp handle_mode_change(socket, key) do
    new_mode =
      case key do
        "i" -> :insert
        "a" -> :insert
        ":" -> :command
        "/" -> :command
      end

    socket
    |> assign(:vim_mode, new_mode)
    |> assign(:pending_g, false)
  end

  defp handle_history_navigation(socket, "ArrowUp"), do: navigate_history_up(socket)
  defp handle_history_navigation(socket, "ArrowDown"), do: navigate_history_down(socket)
  defp handle_history_navigation(socket, _key), do: socket

  defp navigate_history_up(socket) do
    history = socket.assigns.input_history
    current_index = socket.assigns.input_history_index
    history_length = length(history)

    if history_length == 0 do
      socket
    else
      new_index =
        case current_index do
          nil -> 0
          i when i < history_length - 1 -> i + 1
          i -> i
        end

      new_input = Enum.at(history, new_index, "")

      socket
      |> assign(:input, new_input)
      |> assign(:input_history_index, new_index)
    end
  end

  defp navigate_history_down(socket) do
    history = socket.assigns.input_history
    current_index = socket.assigns.input_history_index

    if length(history) == 0 do
      socket
    else
      case current_index do
        nil ->
          socket

        0 ->
          socket
          |> assign(:input, "")
          |> assign(:input_history_index, nil)

        i when i > 0 ->
          new_index = i - 1
          new_input = Enum.at(history, new_index, "")

          socket
          |> assign(:input, new_input)
          |> assign(:input_history_index, new_index)
      end
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

  defp handle_tmux_key(socket, key) do
    case key do
      # % - toggle roster panel visibility
      "%" ->
        socket
        |> assign(:roster_visible, not socket.assigns.roster_visible)
        |> assign(:tmux_prefix, false)

      # x - close active panel
      "x" ->
        socket =
          if socket.assigns.active_pane == :right and socket.assigns.roster_visible do
            assign(socket, :roster_visible, false)
          else
            socket
          end

        assign(socket, :tmux_prefix, false)

      # h - focus left pane (main chat area)
      "h" ->
        socket
        |> assign(:active_pane, :left)
        |> assign(:tmux_prefix, false)

      # l - focus right pane (roster)
      "l" ->
        socket
        |> assign(:active_pane, :right)
        |> assign(:tmux_prefix, false)

      # z - toggle zoom
      "z" ->
        socket
        |> assign(:zoom, not socket.assigns.zoom)
        |> assign(:tmux_prefix, false)

      # Any other key clears tmux_prefix
      _ ->
        assign(socket, :tmux_prefix, false)
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
    # Return plain text - HEEx will auto-escape HTML entities
    # This prevents XSS attacks by escaping <, >, & characters
    # TODO: Add markdown-to-HTML rendering via Earmark for rich text display
    item.content || ""
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
    args = if args == [], do: nil, else: List.first(args)

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

  defp dispatch_skill_or_command(socket, command_name, args) do
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
            Deft.Agent.inject_skill(agent, definition, args)
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

  defp format_tool_result({:ok, output}) when is_binary(output), do: output
  defp format_tool_result({:ok, output}), do: inspect(output, pretty: true)
  defp format_tool_result({:error, reason}) when is_binary(reason), do: "Error: #{reason}"
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason, pretty: true)}"
  defp format_tool_result(other), do: inspect(other, pretty: true)

  defp count_leads(agent_statuses) do
    Enum.count(agent_statuses, fn status -> Map.get(status, :type) == :lead end)
  end

  defp count_completed_leads(agent_statuses) do
    Enum.count(agent_statuses, fn status ->
      Map.get(status, :type) == :lead and Map.get(status, :state) == :complete
    end)
  end

  defp compute_elapsed_seconds(job_started_at) when is_integer(job_started_at) do
    System.system_time(:second) - job_started_at
  end

  defp compute_elapsed_seconds(_), do: 0
end
