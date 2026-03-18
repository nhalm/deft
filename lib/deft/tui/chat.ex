defmodule Deft.TUI.Chat do
  @moduledoc """
  Main chat view for Deft's terminal UI.

  Built on Breeze (LiveView-style TUI), this view provides:
  - Scrollable conversation display with streaming LLM output
  - Tool execution display with spinners and completion status
  - Always-visible status bar showing tokens, cost, turn count, agent state
  - Input area for user prompts

  Subscribes to agent events via Registry and updates display in real-time.
  """

  use Breeze.View

  alias Deft.SlashCommand
  alias Deft.TUI.Markdown

  @doc """
  Mounts the chat view.

  Subscribes to agent events via Registry for the given session_id.

  ## Parameters

  - `params` - Map containing:
    - `:session_id` - The session ID to subscribe to
    - `:agent_pid` - The agent process PID
    - `:config` - Session configuration

  - `term` - The Breeze terminal state
  """
  def mount(params, term) do
    session_id = Map.fetch!(params, :session_id)
    agent_pid = Map.fetch!(params, :agent_pid)
    config = Map.fetch!(params, :config)

    # Subscribe to agent events via Registry
    Registry.register(Deft.Registry, {:session, session_id}, [])

    # Initialize state
    term =
      term
      |> assign(
        session_id: session_id,
        agent_pid: agent_pid,
        config: config,
        messages: [],
        current_text: "",
        streaming: false,
        agent_state: :idle,
        input: "",
        input_history: [],
        input_history_index: nil,
        # Paste detection for multi-line input
        last_char_timestamp: nil,
        # Tool execution state
        active_tools: %{},
        # Token/cost tracking
        current_tokens: 0,
        context_window: Map.get(config, :context_window, 200_000),
        session_cost: 0.0,
        turn_count: 0,
        max_turns: Map.get(config, :turn_limit, 25),
        # OM state (memory tracking)
        memory_tokens: nil,
        memory_threshold: 40_000,
        om_active: false,
        om_sync_fallback: false,
        # Scroll state
        scroll_offset: 0,
        # Raw mode (bypass markdown rendering)
        raw_mode: false,
        # Job state (orchestration mode)
        job_active: false,
        job_phase: nil,
        job_start_time: nil,
        job_cost: 0.0,
        job_cost_ceiling: nil,
        job_leads: %{},
        job_lead_count: 0,
        job_completed_count: 0
      )

    {:ok, term}
  end

  @doc """
  Renders the chat view.

  Layout:
  - Header with model name
  - Scrollable conversation area
  - Input area (with prompt)
  - Status bar
  """
  def render(assigns) do
    assigns =
      assign(assigns,
        model_name: assigns.config[:model] || "claude-sonnet-4",
        agent_state_display:
          format_agent_state(assigns.agent_state, assigns.om_active, assigns.om_sync_fallback),
        streaming_rendered: calculate_streaming_rendered(assigns)
      )

    ~H"""
    <box>
      <box style="bold border">Deft - <%= @model_name %></box>

      <box style="border height-20">
        <%= for message <- @messages do %>
          <%= render_message(message, @raw_mode) %>
        <% end %>
        <%= if @streaming and @streaming_rendered != "" do %>
          <box><%= @streaming_rendered %></box>
        <% end %>
        <%= if @streaming do %>
          <box>▊</box>
        <% end %>
        <%= for {_tool_id, tool_info} <- @active_tools do %>
          <%= render_tool(tool_info) %>
        <% end %>
      </box>

      <box style="border">
        <box>> <%= @input %></box>
      </box>

      <box style="border">
        <box>
          <%= if @job_active do %>
            <%= format_job_status(assigns) %>
          <% else %>
            <%= format_tokens(@current_tokens, @context_window) %> │
            <%= format_memory(@memory_tokens, @memory_threshold) %> │
            <%= format_cost(@session_cost) %> │
            turn <%= @turn_count %>/<%= @max_turns %> │
            <%= @agent_state_display %>
          <% end %>
        </box>
      </box>
    </box>
    """
  end

  @doc """
  Handles agent events from the Registry subscription.

  Events include:
  - Text deltas (streaming LLM output)
  - Tool execution events
  - State changes
  - Token usage updates
  """
  def handle_info({:agent_event, {:text_delta, delta}}, term) do
    handle_text_delta(delta, term)
  end

  def handle_info({:agent_event, {:tool_call_start, %{id: id, name: name}}}, term) do
    handle_tool_start(id, name, term)
  end

  def handle_info({:agent_event, {:tool_call_done, %{id: id, args: args}}}, term) do
    handle_tool_done(id, args, term)
  end

  def handle_info({:agent_event, {:tool_execution_complete, %{id: id} = event}}, term) do
    handle_tool_execution_complete(id, event, term)
  end

  def handle_info({:agent_event, {:state_change, new_state}}, term) do
    handle_state_change(new_state, term)
  end

  def handle_info({:agent_event, {:usage, %{input: input_tokens, output: output_tokens}}}, term) do
    handle_usage(input_tokens, output_tokens, term)
  end

  def handle_info({:agent_event, {:error, reason}}, term) do
    handle_error(reason, term)
  end

  def handle_info({:agent_event, {:retry, retry_count, max_retries, delay}}, term) do
    handle_retry(retry_count, max_retries, delay, term)
  end

  def handle_info({:agent_event, {:turn_limit_reached, turn_count, max_turns}}, term) do
    handle_turn_limit_reached(turn_count, max_turns, term)
  end

  def handle_info({:agent_event, {:abort, _state}}, term) do
    handle_abort(term)
  end

  # OM (Observational Memory) events
  def handle_info({:om, :observation_started}, term) do
    {:noreply, assign(term, om_active: true, om_sync_fallback: false)}
  end

  def handle_info({:om, :observation_complete, metadata}, term) do
    # Extract tokens_produced from metadata and update memory_tokens
    memory_tokens =
      case metadata do
        %{tokens_produced: tokens} -> tokens
        _ -> term.assigns.memory_tokens
      end

    {:noreply, assign(term, om_active: false, memory_tokens: memory_tokens)}
  end

  def handle_info({:om, :reflection_started, _metadata}, term) do
    {:noreply, assign(term, om_active: true, om_sync_fallback: false)}
  end

  def handle_info({:om, :reflection_complete, metadata}, term) do
    # Extract after_tokens from metadata and update memory_tokens
    memory_tokens =
      case metadata do
        %{after_tokens: tokens} -> tokens
        _ -> term.assigns.memory_tokens
      end

    {:noreply, assign(term, om_active: false, memory_tokens: memory_tokens)}
  end

  def handle_info({:om, :buffering_started, _metadata}, term) do
    {:noreply, assign(term, om_active: true, om_sync_fallback: false)}
  end

  def handle_info({:om, :buffering_complete, _metadata}, term) do
    {:noreply, assign(term, om_active: false)}
  end

  def handle_info({:om, :sync_fallback, _metadata}, term) do
    {:noreply, assign(term, om_active: true, om_sync_fallback: true)}
  end

  def handle_info({:om, :activation, _metadata}, term) do
    # Activation is instant, no spinner needed
    {:noreply, term}
  end

  # Job events (orchestration mode)
  def handle_info({:job_event, {:job_started, metadata}}, term) do
    handle_job_started(metadata, term)
  end

  def handle_info({:job_event, {:job_phase_change, phase}}, term) do
    {:noreply, assign(term, job_phase: phase)}
  end

  def handle_info({:job_event, {:lead_started, lead_info}}, term) do
    handle_lead_started(lead_info, term)
  end

  def handle_info({:job_event, {:lead_completed, lead_id}}, term) do
    handle_lead_completed(lead_id, term)
  end

  def handle_info({:job_event, {:lead_status_change, lead_id, status}}, term) do
    handle_lead_status_change(lead_id, status, term)
  end

  def handle_info({:job_event, {:job_cost_update, cost}}, term) do
    {:noreply, assign(term, job_cost: cost)}
  end

  def handle_info({:job_event, {:job_completed, _metadata}}, term) do
    handle_job_completed(term)
  end

  # Ignore events that don't need display updates
  def handle_info({:agent_event, {:thinking_delta, _delta}}, term), do: {:noreply, term}
  def handle_info({:agent_event, {:tool_call_delta, _}}, term), do: {:noreply, term}
  def handle_info({:agent_event, _event}, term), do: {:noreply, term}
  def handle_info({:om, _event}, term), do: {:noreply, term}
  def handle_info({:job_event, _event}, term), do: {:noreply, term}

  def handle_info(_msg, term) do
    {:noreply, term}
  end

  @doc """
  Handles keyboard input events.

  - Enter: submit prompt
  - Shift+Enter: insert newline (Kitty protocol)
  - Backslash + Enter: insert newline (fallback)
  - Ctrl+C / Ctrl+D: quit
  - Ctrl+L: clear screen
  - Up/Down: input history navigation
  """
  # Shift+Enter: insert newline (Kitty protocol support)
  def handle_event(_event, %{"key" => key}, term)
      when key in ["shift-enter", "S-enter", "Shift-Enter"] do
    # Insert newline without submitting
    new_input = term.assigns.input <> "\n"
    {:noreply, assign(term, input: new_input, last_char_timestamp: current_timestamp())}
  end

  # Regular Enter: check for backslash escape or submit
  def handle_event(_event, %{"key" => "enter"}, term) do
    # Check if input ends with backslash (escape for newline)
    if String.ends_with?(term.assigns.input, "\\") do
      # Remove the trailing backslash and add newline
      new_input = String.slice(term.assigns.input, 0..-2//1) <> "\n"
      {:noreply, assign(term, input: new_input, last_char_timestamp: current_timestamp())}
    else
      # Submit the input
      input = String.trim(term.assigns.input)

      if input != "" do
        # Handle slash commands or send prompt
        case handle_user_input(input, term) do
          {:submit, text} ->
            # Add to history
            history = [input | term.assigns.input_history]

            # Send prompt to agent
            Deft.Agent.prompt(term.assigns.agent_pid, text)

            # Clear input
            new_term =
              term
              |> assign(input: "")
              |> assign(input_history: history)
              |> assign(input_history_index: nil)
              |> assign(last_char_timestamp: nil)

            {:noreply, new_term}

          {:command_handled, new_term} ->
            # Command was handled, clear input
            history = [input | term.assigns.input_history]

            new_term =
              new_term
              |> assign(input: "")
              |> assign(input_history: history)
              |> assign(input_history_index: nil)
              |> assign(last_char_timestamp: nil)

            {:noreply, new_term}

          {:quit, term} ->
            # Quit command - stop the view
            {:stop, term}
        end
      else
        {:noreply, term}
      end
    end
  end

  def handle_event(_event, %{"key" => "ctrl-c"}, term) do
    # Ctrl+C: abort current operation if active, exit if idle
    if term.assigns.agent_state == :idle do
      {:stop, term}
    else
      # Agent is active - send abort signal and stay in session
      Deft.Agent.abort(term.assigns.agent_pid)
      {:noreply, term}
    end
  end

  def handle_event(_event, %{"key" => "ctrl-d"}, term) do
    # Ctrl+D: always quit (standard Unix EOF)
    {:stop, term}
  end

  def handle_event(_event, %{"key" => "ctrl-l"}, term) do
    # Clear screen - reset messages
    {:noreply, assign(term, messages: [], current_text: "")}
  end

  def handle_event(_event, %{"key" => "ctrl-r"}, term) do
    # Ctrl+R: toggle raw output mode
    {:noreply, assign(term, raw_mode: !term.assigns.raw_mode)}
  end

  def handle_event(_event, %{"key" => "up"}, term) do
    # Navigate input history - previous entry
    handle_history_navigation(:prev, term)
  end

  def handle_event(_event, %{"key" => "down"}, term) do
    # Navigate input history - next entry
    handle_history_navigation(:next, term)
  end

  def handle_event(_event, %{"key" => key}, term) when key in ["page-up", "Page Up", "pageup"] do
    # Scroll conversation up (show older messages)
    new_offset = term.assigns.scroll_offset + 10
    {:noreply, assign(term, scroll_offset: new_offset)}
  end

  def handle_event(_event, %{"key" => key}, term)
      when key in ["page-down", "Page Down", "pagedown"] do
    # Scroll conversation down (show newer messages)
    new_offset = max(0, term.assigns.scroll_offset - 10)
    {:noreply, assign(term, scroll_offset: new_offset)}
  end

  def handle_event(_event, %{"key" => "backspace"}, term) do
    # Remove last character from input
    new_input =
      if String.length(term.assigns.input) > 0 do
        String.slice(term.assigns.input, 0..-2//1)
      else
        ""
      end

    {:noreply, assign(term, input: new_input)}
  end

  def handle_event(_event, %{"key" => key}, term) when key in ["esc", "escape"] do
    # Esc: cancel current input or abort current operation
    if term.assigns.input != "" do
      # Clear input buffer
      {:noreply, assign(term, input: "", input_history_index: nil)}
    else
      # No input - abort current operation if agent is active
      if term.assigns.agent_state != :idle do
        Deft.Agent.abort(term.assigns.agent_pid)
        {:noreply, term}
      else
        # Agent idle and no input - do nothing
        {:noreply, term}
      end
    end
  end

  def handle_event(_event, %{"key" => key}, term) do
    # Regular character input - append to input buffer with paste detection
    handle_character_input(key, term)
  end

  def handle_event(_event, _params, term) do
    {:noreply, term}
  end

  # Private functions

  defp handle_character_input(key, term) do
    # Paste detection: if characters arrive within 5ms, preserve newlines
    current_ts = current_timestamp()
    is_paste = is_paste_event?(term.assigns.last_char_timestamp, current_ts)

    # Accept printable characters, and preserve newlines if part of a paste
    if should_append_character?(key, is_paste) do
      new_input = term.assigns.input <> key
      {:noreply, assign(term, input: new_input, last_char_timestamp: current_ts)}
    else
      {:noreply, term}
    end
  end

  defp is_paste_event?(nil, _current_ts), do: false
  defp is_paste_event?(last_ts, current_ts), do: current_ts - last_ts < 5

  defp should_append_character?(key, is_paste) do
    # Accept if printable, or if it's a paste with newlines
    String.printable?(key) or (is_paste and String.contains?(key, "\n"))
  end

  defp handle_text_delta(delta, term) do
    new_text = term.assigns.current_text <> delta

    new_term =
      term
      |> assign(current_text: new_text)
      |> assign(streaming: true)

    {:noreply, new_term}
  end

  defp handle_tool_start(id, name, term) do
    # Add tool to active tools map with spinner state
    tool_info = %{
      id: id,
      name: name,
      status: :running,
      start_time: System.monotonic_time(:millisecond)
    }

    new_active_tools = Map.put(term.assigns.active_tools, id, tool_info)
    {:noreply, assign(term, active_tools: new_active_tools)}
  end

  defp handle_tool_done(id, args, term) do
    # Update tool with parsed args (execution not complete yet)
    case Map.get(term.assigns.active_tools, id) do
      nil ->
        {:noreply, term}

      tool_info ->
        key_arg = extract_key_arg(tool_info.name, args)
        updated_tool = Map.put(tool_info, :key_arg, key_arg)
        new_active_tools = Map.put(term.assigns.active_tools, id, updated_tool)
        {:noreply, assign(term, active_tools: new_active_tools)}
    end
  end

  defp handle_tool_execution_complete(id, %{success: success, duration: duration}, term) do
    # Update tool status to done or error with duration
    case Map.get(term.assigns.active_tools, id) do
      nil ->
        {:noreply, term}

      tool_info ->
        status = if success, do: :done, else: :error

        updated_tool =
          tool_info
          |> Map.put(:status, status)
          |> Map.put(:duration, duration)

        new_active_tools = Map.put(term.assigns.active_tools, id, updated_tool)
        {:noreply, assign(term, active_tools: new_active_tools)}
    end
  end

  defp handle_state_change(new_state, term) do
    new_term = assign(term, agent_state: new_state)

    # When transitioning to idle, commit current streaming text and clear tools
    new_term =
      if new_state == :idle do
        commit_streaming_message(new_term)
      else
        new_term
      end

    {:noreply, new_term}
  end

  defp handle_usage(input_tokens, output_tokens, term) do
    # Update token counts
    # Note: This is per-turn usage, not cumulative
    new_current_tokens = input_tokens

    new_cost =
      term.assigns.session_cost + calculate_cost(input_tokens, output_tokens, term.assigns.config)

    new_term =
      term
      |> assign(current_tokens: new_current_tokens)
      |> assign(session_cost: new_cost)
      |> assign(turn_count: term.assigns.turn_count + 1)

    {:noreply, new_term}
  end

  defp handle_error(reason, term) do
    # Add error message to chat
    error_msg = %{
      role: :system,
      content: "Error: #{reason}",
      timestamp: DateTime.utc_now()
    }

    new_messages = term.assigns.messages ++ [error_msg]

    new_term =
      term
      |> assign(messages: new_messages)
      |> assign(streaming: false)
      |> assign(current_text: "")

    {:noreply, new_term}
  end

  defp handle_retry(retry_count, max_retries, delay, term) do
    # Add retry notification to chat
    retry_msg = %{
      role: :system,
      content: "Retrying (#{retry_count}/#{max_retries}) after #{delay}ms...",
      timestamp: DateTime.utc_now()
    }

    new_messages = term.assigns.messages ++ [retry_msg]
    {:noreply, assign(term, messages: new_messages)}
  end

  defp handle_turn_limit_reached(turn_count, max_turns, term) do
    # Add turn limit notification
    limit_msg = %{
      role: :system,
      content:
        "Turn limit reached (#{turn_count}/#{max_turns}). Type 'continue' to proceed or a new prompt.",
      timestamp: DateTime.utc_now()
    }

    new_messages = term.assigns.messages ++ [limit_msg]
    {:noreply, assign(term, messages: new_messages)}
  end

  defp handle_abort(term) do
    # Add abort notification
    abort_msg = %{
      role: :system,
      content: "Operation aborted.",
      timestamp: DateTime.utc_now()
    }

    new_messages = term.assigns.messages ++ [abort_msg]

    new_term =
      term
      |> assign(messages: new_messages)
      |> assign(streaming: false)
      |> assign(current_text: "")
      |> assign(active_tools: %{})

    {:noreply, new_term}
  end

  defp commit_streaming_message(term) do
    if term.assigns.current_text != "" do
      # Create assistant message with the accumulated text
      message = %{
        role: :assistant,
        content: term.assigns.current_text,
        timestamp: DateTime.utc_now()
      }

      term
      |> assign(messages: term.assigns.messages ++ [message])
      |> assign(current_text: "")
      |> assign(streaming: false)
      |> assign(active_tools: %{})
    else
      term
      |> assign(streaming: false)
      |> assign(active_tools: %{})
    end
  end

  defp handle_history_navigation(:prev, term) do
    history = term.assigns.input_history

    if Enum.empty?(history) do
      {:noreply, term}
    else
      current_index = term.assigns.input_history_index

      new_index =
        case current_index do
          nil -> 0
          idx when idx < length(history) - 1 -> idx + 1
          idx -> idx
        end

      new_input = Enum.at(history, new_index)

      new_term =
        term
        |> assign(input: new_input)
        |> assign(input_history_index: new_index)

      {:noreply, new_term}
    end
  end

  defp handle_history_navigation(:next, term) do
    case term.assigns.input_history_index do
      nil ->
        {:noreply, term}

      0 ->
        # Back to empty input
        new_term =
          term
          |> assign(input: "")
          |> assign(input_history_index: nil)

        {:noreply, new_term}

      idx ->
        new_index = idx - 1
        new_input = Enum.at(term.assigns.input_history, new_index)

        new_term =
          term
          |> assign(input: new_input)
          |> assign(input_history_index: new_index)

        {:noreply, new_term}
    end
  end

  defp handle_user_input(input, term) do
    cond do
      # Handle /quit command directly in TUI
      input == "/quit" ->
        {:quit, term}

      # Handle /clear command directly in TUI
      input == "/clear" ->
        new_term = assign(term, messages: [], current_text: "")
        {:command_handled, new_term}

      # Handle /help command directly in TUI
      input == "/help" ->
        help_msg = %{
          role: :system,
          content: build_help_text(),
          timestamp: DateTime.utc_now()
        }

        new_term = assign(term, messages: term.assigns.messages ++ [help_msg])
        {:command_handled, new_term}

      # Handle /status command for job status display
      input == "/status" ->
        status_msg = %{
          role: :system,
          content: build_status_text(term),
          timestamp: DateTime.utc_now()
        }

        new_term = assign(term, messages: term.assigns.messages ++ [status_msg])
        {:command_handled, new_term}

      # Handle /inspect command for Lead site log entries
      String.starts_with?(input, "/inspect") ->
        inspect_msg = %{
          role: :system,
          content: build_inspect_text(input, term),
          timestamp: DateTime.utc_now()
        }

        new_term = assign(term, messages: term.assigns.messages ++ [inspect_msg])
        {:command_handled, new_term}

      # Other slash commands are dispatched via SlashCommand module
      String.starts_with?(input, "/") ->
        handle_slash_command(input, term)

      # Regular text - submit to agent
      true ->
        {:submit, input}
    end
  end

  defp handle_slash_command(input, term) do
    case SlashCommand.parse(input) do
      {:command, name, args} ->
        case SlashCommand.dispatch(name) do
          {:ok, :command, definition} ->
            # Commands are injected as user messages
            # Combine the definition with args for context
            full_text = if args != "", do: "#{definition}\n\nArgs: #{args}", else: definition
            {:submit, full_text}

          {:ok, :skill, definition} ->
            # Skills need to be injected as system instructions before the next agent turn
            # For now, send to agent with skill marker
            # TODO: Proper skill injection will be implemented with agent skill support
            full_text = if args != "", do: "#{definition}\n\nArgs: #{args}", else: definition
            {:submit, full_text}

          {:error, :not_found, command_name} ->
            error_msg = %{
              role: :system,
              content: "Unknown command: /#{command_name}",
              timestamp: DateTime.utc_now()
            }

            new_term = assign(term, messages: term.assigns.messages ++ [error_msg])
            {:command_handled, new_term}

          {:error, :no_definition, command_name} ->
            error_msg = %{
              role: :system,
              content: "Command /#{command_name} exists but has no definition",
              timestamp: DateTime.utc_now()
            }

            new_term = assign(term, messages: term.assigns.messages ++ [error_msg])
            {:command_handled, new_term}
        end

      {:not_slash, text} ->
        # This shouldn't happen since we already checked for "/" prefix
        {:submit, text}
    end
  end

  # Rendering helpers

  defp calculate_streaming_rendered(assigns) do
    # Return empty if not streaming or no current text
    if assigns.streaming and assigns.current_text != "" do
      # If raw mode is enabled, show raw text
      if assigns.raw_mode do
        assigns.current_text
      else
        # Use Markdown.render_streaming/1 to buffer incomplete lines
        # and only render complete blocks
        {rendered, _buffer} = Markdown.render_streaming(assigns.current_text)
        rendered
      end
    else
      ""
    end
  end

  defp render_message(%{role: :user, content: content}, _raw_mode) do
    assigns = %{content: content}

    ~H"""
    <box>
      <box style="bold">User:</box>
      <box><%= @content %></box>
    </box>
    """
  end

  defp render_message(%{role: :assistant, content: content}, raw_mode) do
    # Render markdown for assistant messages unless raw_mode is enabled
    rendered = if raw_mode, do: content, else: Markdown.render(content)
    assigns = %{content: rendered}

    ~H"""
    <box>
      <box style="bold">Assistant:</box>
      <box><%= @content %></box>
    </box>
    """
  end

  defp render_message(%{role: :system, content: content}, _raw_mode) do
    assigns = %{content: content}

    ~H"""
    <box style="dim">
      <box><%= @content %></box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :running, key_arg: key_arg}) when not is_nil(key_arg) do
    assigns = %{name: name, key_arg: key_arg}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] <%= @key_arg %> ◌</box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :running}) do
    assigns = %{name: name}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] ◌</box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :done, duration: duration, key_arg: key_arg})
       when not is_nil(key_arg) do
    duration_sec = duration / 1000
    assigns = %{name: name, key_arg: key_arg, duration: duration_sec}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] <%= @key_arg %> ✓ (<%= Float.round(@duration, 1) %>s)</box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :done, duration: duration}) do
    duration_sec = duration / 1000
    assigns = %{name: name, duration: duration_sec}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] ✓ (<%= Float.round(@duration, 1) %>s)</box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :error, duration: duration, key_arg: key_arg})
       when not is_nil(key_arg) do
    duration_sec = duration / 1000
    assigns = %{name: name, key_arg: key_arg, duration: duration_sec}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] <%= @key_arg %> ✗ (<%= Float.round(@duration, 1) %>s)</box>
    </box>
    """
  end

  defp render_tool(%{name: name, status: :error, duration: duration}) do
    duration_sec = duration / 1000
    assigns = %{name: name, duration: duration_sec}

    ~H"""
    <box>
      <box>[Tool: <%= @name %>] ✗ (<%= Float.round(@duration, 1) %>s)</box>
    </box>
    """
  end

  defp render_tool(_), do: nil

  # Status bar formatting

  defp format_tokens(current, window) do
    # Format as "12.4k/200k"
    current_k = format_k(current)
    window_k = format_k(window)
    "#{current_k}/#{window_k}"
  end

  defp format_memory(nil, _threshold) do
    "memory: --"
  end

  defp format_memory(tokens, threshold) do
    tokens_k = format_k(tokens)
    threshold_k = format_k(threshold)
    "memory: #{tokens_k}/#{threshold_k}"
  end

  defp format_cost(cost) do
    "$#{Float.round(cost, 2)}"
  end

  # When in sync fallback, always show "memorizing..." regardless of agent state
  defp format_agent_state(_agent_state, _om_active, true) do
    "◉ memorizing..."
  end

  # When OM is active (but not sync fallback), show spinner with agent state
  defp format_agent_state(:idle, true, false), do: "◌ idle (observing)"
  defp format_agent_state(:calling, true, false), do: "◉ calling (observing)"
  defp format_agent_state(:streaming, true, false), do: "◉ streaming (observing)"
  defp format_agent_state(:executing_tools, true, false), do: "◉ tools (observing)"
  defp format_agent_state(state, true, false), do: "◉ #{state} (observing)"

  # Normal states when OM is not active
  defp format_agent_state(:idle, false, false), do: "○ idle"
  defp format_agent_state(:calling, false, false), do: "◉ calling"
  defp format_agent_state(:streaming, false, false), do: "◉ streaming"
  defp format_agent_state(:executing_tools, false, false), do: "◉ tools"
  defp format_agent_state(state, false, false), do: "◉ #{state}"

  defp format_k(num) when num < 1000, do: "#{num}"
  defp format_k(num), do: "#{Float.round(num / 1000, 1)}k"

  # Helper functions

  defp extract_key_arg(tool_name, args) when tool_name in ["read", "write", "edit"] do
    Map.get(args, "file_path") || Map.get(args, "path")
  end

  defp extract_key_arg("bash", args), do: Map.get(args, "command")
  defp extract_key_arg("grep", args), do: Map.get(args, "pattern")
  defp extract_key_arg("ls", args), do: Map.get(args, "path") || "."

  defp extract_key_arg("find", args) do
    Map.get(args, "name") || Map.get(args, "pattern")
  end

  defp extract_key_arg("cache_read", args), do: Map.get(args, "key")
  defp extract_key_arg(_tool_name, _args), do: nil

  defp calculate_cost(input_tokens, output_tokens, config) do
    # Get model pricing from config or use defaults
    # Anthropic pricing (as of Jan 2025):
    # Sonnet: $3/MTok input, $15/MTok output
    # Opus: $15/MTok input, $75/MTok output
    # Haiku: $0.25/MTok input, $1.25/MTok output

    model = config[:model] || "claude-sonnet-4"

    {input_price, output_price} =
      cond do
        String.contains?(model, "opus") -> {15.0, 75.0}
        String.contains?(model, "haiku") -> {0.25, 1.25}
        true -> {3.0, 15.0}
      end

    input_cost = input_tokens / 1_000_000 * input_price
    output_cost = output_tokens / 1_000_000 * output_price

    input_cost + output_cost
  end

  defp build_help_text do
    """
    Deft Commands:
    /help         - Show this help
    /clear        - Clear the conversation display
    /quit         - Exit Deft

    Keyboard Shortcuts:
    Enter         - Submit prompt
    Shift+Enter   - Insert newline (multi-line input)
    \\ + Enter     - Insert newline (fallback)
    Ctrl+C/Ctrl+D - Exit
    Ctrl+L        - Clear screen
    Up/Down       - Navigate input history
    """
  end

  defp current_timestamp do
    System.monotonic_time(:millisecond)
  end

  # Job event handlers

  defp handle_job_started(metadata, term) do
    cost_ceiling = Map.get(metadata, :cost_ceiling, 10.0)
    lead_count = Map.get(metadata, :lead_count, 0)

    new_term =
      term
      |> assign(job_active: true)
      |> assign(job_phase: :planning)
      |> assign(job_start_time: System.monotonic_time(:millisecond))
      |> assign(job_cost: 0.0)
      |> assign(job_cost_ceiling: cost_ceiling)
      |> assign(job_lead_count: lead_count)
      |> assign(job_completed_count: 0)
      |> assign(job_leads: %{})

    {:noreply, new_term}
  end

  defp handle_lead_started(lead_info, term) do
    lead_id = Map.fetch!(lead_info, :lead_id)
    deliverable = Map.get(lead_info, :deliverable, "")

    lead_status = %{
      id: lead_id,
      deliverable: deliverable,
      status: :running,
      started_at: System.monotonic_time(:millisecond)
    }

    new_leads = Map.put(term.assigns.job_leads, lead_id, lead_status)
    {:noreply, assign(term, job_leads: new_leads)}
  end

  defp handle_lead_completed(lead_id, term) do
    case Map.get(term.assigns.job_leads, lead_id) do
      nil ->
        {:noreply, term}

      lead_status ->
        updated_status = Map.put(lead_status, :status, :complete)
        new_leads = Map.put(term.assigns.job_leads, lead_id, updated_status)
        new_completed = term.assigns.job_completed_count + 1

        {:noreply, assign(term, job_leads: new_leads, job_completed_count: new_completed)}
    end
  end

  defp handle_lead_status_change(lead_id, status, term) do
    case Map.get(term.assigns.job_leads, lead_id) do
      nil ->
        {:noreply, term}

      lead_status ->
        updated_status = Map.put(lead_status, :status, status)
        new_leads = Map.put(term.assigns.job_leads, lead_id, updated_status)
        {:noreply, assign(term, job_leads: new_leads)}
    end
  end

  defp handle_job_completed(term) do
    new_term =
      term
      |> assign(job_active: false)
      |> assign(job_phase: nil)
      |> assign(job_leads: %{})

    {:noreply, new_term}
  end

  # Job status formatting

  defp format_job_status(assigns) do
    leads_text = "#{assigns.job_lead_count} leads"
    complete_text = "#{assigns.job_completed_count}/#{assigns.job_lead_count} complete"

    cost_text =
      if assigns.job_cost_ceiling do
        "$#{Float.round(assigns.job_cost, 2)}/$#{Float.round(assigns.job_cost_ceiling, 2)}"
      else
        "$#{Float.round(assigns.job_cost, 2)}"
      end

    elapsed_text =
      if assigns.job_start_time do
        elapsed_ms = System.monotonic_time(:millisecond) - assigns.job_start_time
        format_elapsed_time(elapsed_ms)
      else
        "0m"
      end

    phase_display = format_job_phase(assigns.job_phase)

    "#{leads_text} │ #{complete_text} │ #{cost_text} │ #{elapsed_text} elapsed │ #{phase_display}"
  end

  defp format_elapsed_time(ms) when ms < 60_000 do
    seconds = div(ms, 1000)
    "#{seconds}s"
  end

  defp format_elapsed_time(ms) when ms < 3_600_000 do
    minutes = div(ms, 60_000)
    "#{minutes}m"
  end

  defp format_elapsed_time(ms) do
    hours = div(ms, 3_600_000)
    minutes = rem(div(ms, 60_000), 60)
    "#{hours}h#{minutes}m"
  end

  defp format_job_phase(:planning), do: "◉ planning"
  defp format_job_phase(:researching), do: "◉ researching"
  defp format_job_phase(:decomposing), do: "◉ decomposing"
  defp format_job_phase(:executing), do: "◉ executing"
  defp format_job_phase(:verifying), do: "◉ verifying"
  defp format_job_phase(:complete), do: "✓ complete"
  defp format_job_phase(nil), do: "◉ starting"
  defp format_job_phase(phase), do: "◉ #{phase}"

  defp build_status_text(term) do
    if not term.assigns.job_active do
      "No active job"
    else
      phase_text = format_job_phase_verbose(term.assigns.job_phase)

      cost_text =
        if term.assigns.job_cost_ceiling do
          "$#{Float.round(term.assigns.job_cost, 2)} / $#{Float.round(term.assigns.job_cost_ceiling, 2)}"
        else
          "$#{Float.round(term.assigns.job_cost, 2)}"
        end

      elapsed_text =
        if term.assigns.job_start_time do
          elapsed_ms = System.monotonic_time(:millisecond) - term.assigns.job_start_time
          format_elapsed_time_verbose(elapsed_ms)
        else
          "0 seconds"
        end

      leads_text = build_leads_text(term.assigns.job_leads)

      """
      Job Status
      ==========

      Phase: #{phase_text}
      Leads: #{term.assigns.job_completed_count}/#{term.assigns.job_lead_count} complete
      Cost: #{cost_text}
      Elapsed: #{elapsed_text}

      #{leads_text}
      """
    end
  end

  defp format_job_phase_verbose(:planning), do: "Planning"
  defp format_job_phase_verbose(:researching), do: "Researching"
  defp format_job_phase_verbose(:decomposing), do: "Decomposing"
  defp format_job_phase_verbose(:executing), do: "Executing"
  defp format_job_phase_verbose(:verifying), do: "Verifying"
  defp format_job_phase_verbose(:complete), do: "Complete"
  defp format_job_phase_verbose(nil), do: "Starting"
  defp format_job_phase_verbose(phase), do: to_string(phase)

  defp format_elapsed_time_verbose(ms) when ms < 1000, do: "#{ms}ms"

  defp format_elapsed_time_verbose(ms) when ms < 60_000 do
    seconds = div(ms, 1000)
    "#{seconds} seconds"
  end

  defp format_elapsed_time_verbose(ms) when ms < 3_600_000 do
    minutes = div(ms, 60_000)
    seconds = rem(div(ms, 1000), 60)

    if seconds > 0 do
      "#{minutes} minutes, #{seconds} seconds"
    else
      "#{minutes} minutes"
    end
  end

  defp format_elapsed_time_verbose(ms) do
    hours = div(ms, 3_600_000)
    minutes = rem(div(ms, 60_000), 60)
    "#{hours} hours, #{minutes} minutes"
  end

  defp build_leads_text(leads) when map_size(leads) == 0 do
    "No leads started yet"
  end

  defp build_leads_text(leads) do
    leads_list =
      leads
      |> Map.values()
      |> Enum.sort_by(& &1.started_at)
      |> Enum.map(&format_lead_status/1)
      |> Enum.join("\n")

    "Leads:\n#{leads_list}"
  end

  defp format_lead_status(lead) do
    status_icon =
      case lead.status do
        :running -> "◉"
        :waiting -> "○"
        :blocked -> "⊗"
        :complete -> "✓"
        _ -> "○"
      end

    deliverable_text = String.slice(lead.deliverable, 0..50)
    "  #{status_icon} #{lead.id}: #{deliverable_text}"
  end

  defp build_inspect_text(input, term) do
    # Parse /inspect command: /inspect <lead_id> [--last N] [--type TYPE]
    parts = String.split(input, ~r/\s+/, trim: true)

    case parts do
      ["/inspect"] ->
        "Usage: /inspect <lead_id> [--last N] [--type TYPE]"

      ["/inspect", lead_id | opts] ->
        if not term.assigns.job_active do
          "No active job"
        else
          case Map.get(term.assigns.job_leads, lead_id) do
            nil ->
              "Lead not found: #{lead_id}\n\nAvailable leads:\n#{list_available_leads(term.assigns.job_leads)}"

            _lead ->
              # Parse options
              {last_n, type_filter} = parse_inspect_options(opts)

              # TODO: Once orchestration is implemented, this will read from the site log
              # For now, show a placeholder message
              """
              Site Log for Lead: #{lead_id}
              ==============================

              Options:
              - Last N entries: #{last_n || "all"}
              - Type filter: #{type_filter || "all"}

              (Site log entries will appear here once orchestration is implemented)
              """
          end
        end

      _ ->
        "Usage: /inspect <lead_id> [--last N] [--type TYPE]"
    end
  end

  defp parse_inspect_options(opts) do
    parse_inspect_options(opts, nil, nil)
  end

  defp parse_inspect_options([], last_n, type_filter), do: {last_n, type_filter}

  defp parse_inspect_options(["--last", n | rest], _last_n, type_filter) do
    case Integer.parse(n) do
      {num, ""} -> parse_inspect_options(rest, num, type_filter)
      _ -> parse_inspect_options(rest, nil, type_filter)
    end
  end

  defp parse_inspect_options(["--type", type | rest], last_n, _type_filter) do
    parse_inspect_options(rest, last_n, type)
  end

  defp parse_inspect_options([_unknown | rest], last_n, type_filter) do
    parse_inspect_options(rest, last_n, type_filter)
  end

  defp list_available_leads(leads) when map_size(leads) == 0 do
    "  (no leads started yet)"
  end

  defp list_available_leads(leads) do
    leads
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&"  - #{&1}")
    |> Enum.join("\n")
  end
end
