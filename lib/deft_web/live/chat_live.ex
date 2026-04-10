defmodule DeftWeb.ChatLive do
  @moduledoc """
  Main chat interface LiveView.

  Displays real-time agent conversation with streaming output, tool execution,
  thinking blocks, and agent roster. Supports vim/tmux-style keybindings.
  """

  use DeftWeb, :live_view

  require Logger

  alias Deft.Config
  alias Deft.Session
  alias Deft.Session.Supervisor, as: SessionSupervisor
  alias Deft.Session.Worker
  alias Deft.Skills.Registry, as: SkillsRegistry
  alias Phoenix.HTML

  import DeftWeb.Components.Thinking
  import DeftWeb.Components.ToolCall
  import DeftWeb.Components.StatusBar
  import DeftWeb.Components.Roster

  @impl true
  def mount(params, _session, socket) do
    # Get session_id from URL params (e.g., /?session=abc123)
    session_id = params["session"]

    if is_nil(session_id) do
      # Auto-create a new session and load it
      new_session_id = generate_session_id()
      working_dir = File.cwd!()
      config = Config.load(%{}, working_dir)

      # Build agent config from loaded config
      agent_config = %{
        model: config.model,
        provider: Deft.Provider.Anthropic,
        working_dir: working_dir,
        turn_limit: config.turn_limit,
        tool_timeout: config.tool_timeout,
        bash_timeout: config.bash_timeout,
        max_turns: config.turn_limit,
        tools: [
          Deft.Tools.Read,
          Deft.Tools.Write,
          Deft.Tools.Edit,
          Deft.Tools.Bash,
          Deft.Tools.Grep,
          Deft.Tools.Find,
          Deft.Tools.Ls,
          Deft.Tools.UseSkill,
          Deft.Tools.IssueCreate
        ],
        om_enabled: config.om_enabled,
        om_message_token_threshold: config.om_message_token_threshold,
        om_observation_token_threshold: config.om_observation_token_threshold,
        om_buffer_interval: config.om_buffer_interval,
        om_buffer_tail_retention: config.om_buffer_tail_retention,
        om_hard_threshold_multiplier: config.om_hard_threshold_multiplier,
        work_cost_ceiling: config.work_cost_ceiling,
        job_initial_concurrency: config.job_initial_concurrency,
        job_max_leads: config.job_max_leads
      }

      # Create the session metadata entry
      _ = create_session(new_session_id, working_dir, config)

      # Start the session process
      {:ok, _worker_pid} =
        SessionSupervisor.start_session(
          session_id: new_session_id,
          config: agent_config,
          messages: [],
          project_dir: working_dir,
          working_dir: working_dir
        )

      # Redirect to the new session URL — mount will re-run with the session param
      {:ok, redirect(socket, to: "/?session=#{new_session_id}")}
    else
      if connected?(socket) do
        subscribe_to_session(session_id)
      end

      # Initialize all assigns
      socket = initialize_socket_assigns(socket, session_id)

      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:agent_event, {:text_delta, delta}}, socket) do
    # Flush any pending thinking before starting text
    socket = maybe_flush_thinking(socket, socket.assigns.streaming_thinking)
    socket = assign(socket, :streaming_thinking, "")

    new_text = socket.assigns.streaming_text <> delta

    # Render markdown server-side, push as HTML to client-side hook
    html =
      try do
        case Earmark.as_html(new_text, smartypants: false) do
          {:ok, html, _} -> html
          {:error, html, _} -> html
        end
      rescue
        _ ->
          escaped = new_text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
          "<pre>" <> escaped <> "</pre>"
      end

    socket =
      socket
      |> assign(:streaming_text, new_text)
      |> push_event("streaming_markdown", %{html: html})

    {:noreply, socket}
  end

  def handle_info({:agent_event, {:thinking_delta, delta}}, socket) do
    # Flush any pending text before starting thinking
    socket = maybe_flush_text(socket, socket.assigns.streaming_text)
    socket = assign(socket, :streaming_text, "")

    {:noreply, assign(socket, :streaming_thinking, socket.assigns.streaming_thinking <> delta)}
  end

  def handle_info({:agent_event, {:tool_call_start, %{id: id, name: name}}}, socket) do
    # Flush any pending thinking and text before starting tool call
    socket = maybe_flush_thinking(socket, socket.assigns.streaming_thinking)
    socket = assign(socket, :streaming_thinking, "")
    socket = maybe_flush_text(socket, socket.assigns.streaming_text)
    socket = assign(socket, :streaming_text, "")

    tool = %{
      id: id,
      name: name,
      status: :running,
      duration: nil,
      input: nil,
      output: nil,
      key_arg: nil
    }

    active_tools = Map.put(socket.assigns.active_tools, id, tool)
    {:noreply, assign(socket, :active_tools, active_tools)}
  end

  def handle_info({:agent_event, {:tool_call_done, %{id: id, args: args}}}, socket) do
    active_tools = socket.assigns.active_tools

    # Get the tool, or return if missing (can happen on reconnect or missed tool_call_start)
    tool = Map.get(active_tools, id)

    if tool do
      # Extract the key argument to display alongside tool name
      key_arg = extract_key_arg(tool.name, args)

      updated_tool =
        tool
        |> Map.put(:input, Jason.encode!(args, pretty: true))
        |> Map.put(:key_arg, key_arg)

      active_tools = Map.put(active_tools, id, updated_tool)
      {:noreply, assign(socket, :active_tools, active_tools)}
    else
      # Tool not found in active_tools (missed tool_call_start event)
      {:noreply, socket}
    end
  end

  def handle_info(
        {:agent_event,
         {:tool_execution_complete,
          %{id: id, success: success, duration: duration_ms, result: result}}},
        socket
      ) do
    active_tools = socket.assigns.active_tools

    # Get the tool from active_tools (may be missing if we missed earlier events)
    tool = Map.get(active_tools, id, %{id: id, name: "unknown", key_arg: nil, input: nil})

    # Format the result for display
    output = format_tool_result(result)
    status = if success, do: :success, else: :error
    duration_sec = duration_ms / 1000.0

    # Build the completed tool data
    completed_tool =
      tool
      |> Map.merge(%{status: status, duration: duration_sec, output: output})

    # Persist the completed tool to the conversation stream immediately
    socket = flush_tool(socket, completed_tool)

    # Cache the tool details for lazy loading on click
    tool_id = "tool-#{id}"

    completed_tools =
      Map.put(socket.assigns.completed_tools, tool_id, %{
        input: completed_tool[:input],
        output: output
      })

    # Remove the tool from active_tools now that it's persisted
    active_tools = Map.delete(active_tools, id)

    {:noreply,
     socket |> assign(:active_tools, active_tools) |> assign(:completed_tools, completed_tools)}
  end

  def handle_info({:agent_event, {:state_change, state}}, socket) do
    socket =
      if state == :idle do
        # Flush only remaining in-progress content (if any) to conversation stream.
        # Most content will already be persisted by earlier incremental flushes
        # when content type changes (thinking→text, text→tool, etc).
        thinking = socket.assigns.streaming_thinking
        text = socket.assigns.streaming_text

        socket =
          socket
          |> maybe_flush_thinking(thinking)
          |> maybe_flush_text(text)

        # Reset streaming buffers and update state
        # Note: active_tools are cleared immediately when tools complete, not on idle
        socket
        |> assign(:streaming_text, "")
        |> assign(:streaming_thinking, "")
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

  def handle_info({:job_status, statuses}, socket) do
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
      |> assign(:agent_identity, "Foreman")

    {:noreply, socket}
  end

  def handle_info({:agent_event, {:error, reason}}, socket) do
    # Display error message in conversation stream
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :error,
      role: :error,
      content: "Error: #{inspect(reason)}"
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  def handle_info({:agent_event, {:turn_limit_reached, count, max}}, socket) do
    # Display turn limit message and prompt user to continue or abort
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :system,
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

  def handle_info(:shutdown_server, socket) do
    # Actually stop the server and exit
    System.stop(0)
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.warning("[Chat] Unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Private helpers for socket initialization

  defp subscribe_to_session(session_id) do
    # Subscribe to agent events for this session
    _ = Registry.register(Deft.Registry, {:session, session_id}, [])
    _ = Registry.register(Deft.Registry, {:job_status, session_id}, [])

    # Log session connection
    id_prefix = String.slice(session_id, 0, 8)
    Logger.info("[Chat:#{id_prefix}] Session connected")
  end

  defp initialize_socket_assigns(socket, session_id) do
    # Load conversation history from JSONL store
    history_items = load_conversation_history(session_id)

    socket
    |> assign_session_state(session_id)
    |> assign_message_state()
    |> assign_input_state()
    |> assign_tool_state()
    |> assign_metrics_state()
    |> assign_job_state()
    |> assign_ui_state()
    |> stream(:conversation, history_items)
  end

  defp load_conversation_history(session_id) do
    alias Deft.Session.Store

    case Store.load(session_id) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(&entry_to_stream_items/1)

      {:error, _} ->
        []
    end
  end

  defp entry_to_stream_items(%Deft.Session.Entry.Message{role: :user, content: content}) do
    text =
      content
      |> Enum.filter(fn block -> block["type"] == "text" || block[:type] == "text" end)
      |> Enum.map(fn block -> block["text"] || block[:text] || "" end)
      |> Enum.join("\n")

    if text != "" do
      [
        %{
          id: System.unique_integer([:positive, :monotonic]),
          type: :user,
          role: :user,
          content: text
        }
      ]
    else
      []
    end
  end

  defp entry_to_stream_items(%Deft.Session.Entry.Message{role: :assistant, content: content}) do
    Enum.flat_map(content, &content_block_to_stream_item/1)
  end

  defp entry_to_stream_items(_entry), do: []

  defp content_block_to_stream_item(block) do
    case block_field(block, "type") do
      "text" -> text_block_item(block_field(block, "text"))
      "thinking" -> thinking_block_item(block_field(block, "text"))
      "tool_use" -> tool_use_block_item(block)
      _ -> []
    end
  end

  defp block_field(block, key), do: block[key] || block[String.to_existing_atom(key)]

  defp text_block_item(nil), do: []
  defp text_block_item(""), do: []

  defp text_block_item(text) do
    [
      %{
        id: System.unique_integer([:positive, :monotonic]),
        type: :text,
        role: :assistant,
        content: text
      }
    ]
  end

  defp thinking_block_item(nil), do: []
  defp thinking_block_item(""), do: []

  defp thinking_block_item(text) do
    [
      %{
        id: System.unique_integer([:positive, :monotonic]),
        type: :thinking,
        role: :assistant,
        content: text
      }
    ]
  end

  defp tool_use_block_item(block) do
    name = block_field(block, "name") || "unknown"
    args = block_field(block, "args") || %{}
    tool_id = block_field(block, "id")

    [
      %{
        id: System.unique_integer([:positive, :monotonic]),
        type: :tool,
        role: :assistant,
        tool_call_id: tool_id,
        tool: %{
          id: tool_id,
          name: name,
          key_arg: extract_key_arg(name, args),
          status: :success,
          duration: nil
        }
      }
    ]
  end

  defp assign_session_state(socket, session_id) do
    socket
    |> assign(:session_id, session_id)
    |> assign(:repo_name, get_repo_name())
  end

  defp assign_message_state(socket) do
    socket
    |> assign(:messages, [])
    |> assign(:streaming_text, "")
    |> assign(:streaming_thinking, "")
    |> assign(:agent_state, :idle)
  end

  defp assign_input_state(socket) do
    socket
    |> assign(:input, "")
    |> assign(:input_history, [])
    |> assign(:input_history_index, nil)
  end

  defp assign_tool_state(socket) do
    socket
    |> assign(:active_tools, %{})
    |> assign(:completed_tools, %{})
    |> assign(:tool_details_cache, %{})
    |> assign(:tools_expanded, %{})
    |> assign(:thinking_blocks_expanded, %{})
  end

  defp assign_metrics_state(socket) do
    socket
    |> assign(:tokens_input, 0)
    |> assign(:tokens_output, 0)
    |> assign(:cost, 0.0)
    |> assign(:turn_count, 0)
    |> assign(:turn_limit, 25)
    |> assign(:turn_limit_reached, false)
    |> assign(:turn_limit_count, 0)
    |> assign(:turn_limit_max, 0)
    |> assign(:om_observation_count, 0)
    |> assign(:om_memory_tokens, 0)
  end

  defp assign_job_state(socket) do
    socket
    |> assign(:agent_statuses, [])
    |> assign(:job_active, false)
    |> assign(:job_budget, 10.0)
    |> assign(:job_started_at, nil)
    |> assign(:agent_identity, "Solo")
  end

  defp assign_ui_state(socket) do
    socket
    |> assign(:vim_mode, :insert)
    |> assign(:scroll_offset, 0)
    |> assign(:pending_g, false)
    |> assign(:tmux_prefix, false)
    |> assign(:roster_visible, false)
    |> assign(:zoom, false)
    |> assign(:active_pane, :left)
    |> assign(:last_ctrl_c, nil)
    |> assign(:help_visible, false)
  end

  # Private helpers for flushing content to conversation stream

  defp maybe_flush_thinking(socket, "") do
    socket
  end

  defp maybe_flush_thinking(socket, thinking) when is_binary(thinking) do
    message_id = System.unique_integer([:positive, :monotonic])

    message = %{
      id: message_id,
      type: :thinking,
      role: :assistant,
      content: thinking
    }

    # Auto-collapse thinking blocks when they persist to conversation
    thinking_id = "thinking-#{message_id}"

    thinking_blocks_expanded =
      Map.put(socket.assigns.thinking_blocks_expanded, thinking_id, false)

    socket
    |> assign(:thinking_blocks_expanded, thinking_blocks_expanded)
    |> stream_insert(:conversation, message)
  end

  defp maybe_flush_text(socket, "") do
    socket
  end

  defp maybe_flush_text(socket, text) when is_binary(text) do
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :text,
      role: :assistant,
      content: text
    }

    stream_insert(socket, :conversation, message)
  end

  defp flush_tool(socket, tool) do
    compact_tool = Map.drop(tool, [:input, :output])

    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :tool,
      role: :assistant,
      tool: compact_tool,
      tool_call_id: tool[:id]
    }

    stream_insert(socket, :conversation, message)
  end

  @impl true
  def terminate(_reason, socket) do
    session_id = socket.assigns.session_id
    id_prefix = String.slice(session_id, 0, 8)
    Logger.info("[Chat:#{id_prefix}] Session disconnected")
    :ok
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

      # Log user message submit
      id_prefix = String.slice(socket.assigns.session_id, 0, 8)
      input_length = String.length(input)
      Logger.info("[Chat:#{id_prefix}] User submits message, #{input_length} chars")

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
    id_prefix = String.slice(socket.assigns.session_id, 0, 8)
    Logger.debug("[Chat:#{id_prefix}] Event: toggle_thinking")

    current_state = Map.get(socket.assigns.thinking_blocks_expanded, id, true)
    new_expanded_state = Map.put(socket.assigns.thinking_blocks_expanded, id, not current_state)
    {:noreply, assign(socket, :thinking_blocks_expanded, new_expanded_state)}
  end

  @impl true
  def handle_event("continue_turn", _params, socket) do
    id_prefix = String.slice(socket.assigns.session_id, 0, 8)
    Logger.debug("[Chat:#{id_prefix}] Event: continue_turn")

    # Call continue_turn with true to allow the agent to proceed
    agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
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
      type: :system,
      role: :system,
      content: "Continuing turn..."
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  @impl true
  def handle_event("abort_turn", _params, socket) do
    id_prefix = String.slice(socket.assigns.session_id, 0, 8)
    Logger.debug("[Chat:#{id_prefix}] Event: abort_turn")

    # Call continue_turn with false to decline continuing
    agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
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
      type: :system,
      role: :system,
      content: "Declining to continue turn..."
    }

    {:noreply, stream_insert(socket, :conversation, message)}
  end

  def handle_event("new_session", _params, socket) do
    id_prefix = String.slice(socket.assigns.session_id, 0, 8)
    Logger.debug("[Chat:#{id_prefix}] Event: new_session")

    # Create a new session and navigate to it
    new_session_id = Session.create()
    {:noreply, push_navigate(socket, to: "/?session=#{new_session_id}")}
  end

  def handle_event("show_help", _params, socket) do
    id_prefix = String.slice(socket.assigns.session_id, 0, 8)
    Logger.debug("[Chat:#{id_prefix}] Event: show_help")

    # Toggle help visibility
    {:noreply, assign(socket, :help_visible, not socket.assigns.help_visible)}
  end

  def handle_event("prevent_close", _params, socket) do
    # Prevent click propagation from help content to overlay
    {:noreply, socket}
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
      agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
      Deft.Agent.abort(agent)

      message = %{
        id: System.unique_integer([:positive, :monotonic]),
        type: :system,
        role: :system,
        content: "Force aborting agent operation..."
      }

      socket
      |> assign(:last_ctrl_c, nil)
      |> stream_insert(:conversation, message)
    else
      # First Ctrl+c - abort current operation
      agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
      Deft.Agent.abort(agent)

      message = %{
        id: System.unique_integer([:positive, :monotonic]),
        type: :system,
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

  defp handle_scroll_key(socket, "j", false, _pending_g), do: scroll_down(socket, 1, 50)
  defp handle_scroll_key(socket, "k", false, _pending_g), do: scroll_up(socket, 1, 50)
  defp handle_scroll_key(socket, "G", false, _pending_g), do: scroll_to_bottom(socket)
  defp handle_scroll_key(socket, "g", false, false), do: assign(socket, :pending_g, true)
  defp handle_scroll_key(socket, "g", false, true), do: scroll_to_top(socket)
  defp handle_scroll_key(socket, "u", true, _pending_g), do: scroll_up(socket, 10, 250)
  defp handle_scroll_key(socket, "d", true, _pending_g), do: scroll_down(socket, 10, 250)
  defp handle_scroll_key(socket, _key, _ctrl, _pending_g), do: assign(socket, :pending_g, false)

  defp scroll_down(socket, offset_delta, pixel_delta) do
    current_offset = normalize_scroll_offset(socket.assigns.scroll_offset)

    socket
    |> assign(:scroll_offset, current_offset + offset_delta)
    |> assign(:pending_g, false)
    |> push_event("scroll_to", %{delta: pixel_delta})
  end

  defp scroll_up(socket, offset_delta, pixel_delta) do
    current_offset = normalize_scroll_offset(socket.assigns.scroll_offset)

    socket
    |> assign(:scroll_offset, max(0, current_offset - offset_delta))
    |> assign(:pending_g, false)
    |> push_event("scroll_to", %{delta: -pixel_delta})
  end

  defp scroll_to_bottom(socket) do
    socket
    |> assign(:scroll_offset, :bottom)
    |> assign(:pending_g, false)
    |> push_event("scroll_to", %{position: "bottom"})
  end

  defp scroll_to_top(socket) do
    socket
    |> assign(:scroll_offset, 0)
    |> assign(:pending_g, false)
    |> push_event("scroll_to", %{position: "top"})
  end

  defp normalize_scroll_offset(:bottom), do: 0
  defp normalize_scroll_offset(offset) when is_integer(offset), do: offset

  # % - toggle roster panel visibility
  defp handle_tmux_key(socket, "%") do
    socket
    |> assign(:roster_visible, not socket.assigns.roster_visible)
    |> assign(:tmux_prefix, false)
  end

  # x - close active panel
  defp handle_tmux_key(socket, "x") do
    socket =
      if socket.assigns.active_pane == :right and socket.assigns.roster_visible do
        assign(socket, :roster_visible, false)
      else
        socket
      end

    assign(socket, :tmux_prefix, false)
  end

  # h - focus left pane (main chat area)
  defp handle_tmux_key(socket, "h") do
    socket
    |> assign(:active_pane, :left)
    |> assign(:tmux_prefix, false)
  end

  # l - focus right pane (roster)
  defp handle_tmux_key(socket, "l") do
    socket
    |> assign(:active_pane, :right)
    |> assign(:tmux_prefix, false)
  end

  # z - toggle zoom
  defp handle_tmux_key(socket, "z") do
    socket
    |> assign(:zoom, not socket.assigns.zoom)
    |> assign(:tmux_prefix, false)
  end

  # Any other key clears tmux_prefix
  defp handle_tmux_key(socket, _key) do
    assign(socket, :tmux_prefix, false)
  end

  defp get_repo_name do
    case File.cwd() do
      {:ok, path} -> Path.basename(path)
      _ -> "unknown"
    end
  end

  defp generate_session_id do
    # Generate a random 8-byte hex string as session ID
    "sess_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp create_session(session_id, working_dir, config) do
    alias Deft.Session.Entry.SessionStart
    alias Deft.Session.Store

    config_map = Map.from_struct(config)
    session_start = SessionStart.new(session_id, working_dir, config.model, config_map)
    Store.append(session_id, session_start, working_dir)
  end

  defp mode_indicator(:normal), do: "Normal"
  defp mode_indicator(:insert), do: "Insert"
  defp mode_indicator(:command), do: "Command"

  defp activity_label(:thinking), do: "Thinking..."
  defp activity_label(:executing), do: "Working..."
  defp activity_label(:waiting), do: "Waiting..."
  defp activity_label(:researching), do: "Researching..."
  defp activity_label(:implementing), do: "Implementing..."
  defp activity_label(:verifying), do: "Verifying..."
  defp activity_label(state), do: "#{state}..."

  attr(:item, :map, required: true)
  attr(:thinking_expanded, :map, default: %{})
  attr(:tools_expanded, :map, default: %{})
  attr(:session_id, :string, default: nil)

  defp render_conversation_item(assigns) do
    type = Map.get(assigns.item, :type)
    content = Map.get(assigns.item, :content)
    tool = Map.get(assigns.item, :tool)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:content, content)
      |> assign(:tool, tool)

    ~H"""
    <%= case @type do %>
      <% :thinking -> %>
        <.thinking
          id={"thinking-#{@item.id}"}
          content={@content}
          expanded={Map.get(@thinking_expanded, "thinking-#{@item.id}", true)}
        />
      <% :tool -> %>
        <.tool_call
          id={"tool-#{@item.id}"}
          name={Map.get(@tool, :name, "unknown")}
          key_arg={Map.get(@tool, :key_arg)}
          status={Map.get(@tool, :status, :running)}
          duration={Map.get(@tool, :duration)}
          session_id={@session_id}
          tool_call_id={to_string(@item[:tool_call_id] || @tool[:id] || "")}
        />
      <% :text -> %>
        <%= render_markdown(@content) %>
      <% :user -> %>
        <div class="user-message">
          <%= render_markdown(@content) %>
        </div>
      <% :system -> %>
        <div class="system-message">
          <%= @content %>
        </div>
      <% :error -> %>
        <div class="error-message">
          <%= @content %>
        </div>
      <% _ -> %>
        <%= @content %>
    <% end %>
    """
  end

  defp render_markdown(content) do
    # Convert markdown to HTML using Earmark
    # Disable smartypants to preserve literal "..." instead of converting to "…"
    case Earmark.as_html(content, smartypants: false) do
      {:ok, html, []} -> HTML.raw(html)
      {:ok, html, _messages} -> HTML.raw(html)
      {:error, html, _messages} -> HTML.raw(html)
    end
  end

  defp add_user_message(socket, text) do
    # Add user message to conversation stream
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :user,
      role: :user,
      content: text
    }

    stream_insert(socket, :conversation, message)
  end

  defp send_prompt_to_agent(socket, text) do
    agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
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
      type: :system,
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
    message = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: :system,
      role: :system,
      content: "Shutting down..."
    }

    # Schedule shutdown after a brief delay to ensure message is sent to browser
    Process.send_after(self(), :shutdown_server, 500)

    stream_insert(socket, :conversation, message)
  end

  defp dispatch_skill_or_command(socket, command_name, args) do
    case SkillsRegistry.lookup(command_name) do
      :not_found ->
        # Unknown command
        message = %{
          id: System.unique_integer([:positive, :monotonic]),
          type: :system,
          role: :system,
          content: "Unknown command: /#{command_name}. Type /help for available commands."
        }

        stream_insert(socket, :conversation, message)

      _entry ->
        # Load and inject the skill/command
        case SkillsRegistry.load_definition(command_name) do
          {:ok, definition} ->
            agent = Worker.foreman_agent_via_tuple(socket.assigns.session_id)
            Deft.Agent.inject_skill(agent, definition, args)
            socket

          {:error, reason} ->
            message = %{
              id: System.unique_integer([:positive, :monotonic]),
              type: :system,
              role: :system,
              content: "Failed to load command #{command_name}: #{inspect(reason)}"
            }

            stream_insert(socket, :conversation, message)
        end
    end
  end

  defp extract_key_arg(tool_name, args) do
    case tool_name do
      name when name in ["read", "write", "edit"] ->
        Map.get(args, "file_path")

      "bash" ->
        Map.get(args, "command")

      name when name in ["grep", "glob"] ->
        Map.get(args, "pattern")

      _ ->
        # For unknown tools, try common field names or return nil
        Map.get(args, "path") || Map.get(args, "query") || nil
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
