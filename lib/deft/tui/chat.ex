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

    # Subscribe to Foreman job_status broadcasts via ProcessRegistry
    Registry.register(Deft.ProcessRegistry, {:foreman, session_id}, [])

    # Initialize state
    term =
      term
      |> assign(
        session_id: session_id,
        agent_pid: agent_pid,
        config: config,
        messages: [],
        current_text: "",
        current_thinking: "",
        completed_thinking_blocks: [],
        had_non_thinking_event: false,
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
        memory_threshold: config.om_observation_token_threshold,
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
        job_completed_count: 0,
        # Agent roster (orchestration mode)
        agent_statuses: []
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
        model_name: assigns.config[:model] || "claude-sonnet-4-20250514",
        repo_name: extract_repo_name(assigns.config[:working_dir] || File.cwd!()),
        agent_state_display:
          format_agent_state(assigns.agent_state, assigns.om_active, assigns.om_sync_fallback),
        streaming_rendered: calculate_streaming_rendered(assigns),
        visible_messages: calculate_visible_messages(assigns),
        agent_roster: render_agent_roster(assigns.agent_statuses)
      )

    ~H"""
    <box>
      <box style="bold border">
        <%= if @job_active do %>
          Deft ─ <%= @repo_name %> ─ Foreman <%= @agent_state_display %>
        <% else %>
          Deft ─ <%= @repo_name %> ─ model: <%= @model_name %> ─ Solo
        <% end %>
      </box>

      <box style="border height-20">
        <%= if @job_active and length(@agent_roster) > 0 do %>
          <%= for roster_line <- @agent_roster do %>
            <box><%= roster_line %></box>
          <% end %>
        <% end %>
        <%= for message <- @visible_messages do %>
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

  def handle_info({:agent_event, {:thinking_delta, delta}}, term) do
    handle_thinking_delta(delta, term)
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
  def handle_info({:om_event, {:om, :observation_started}}, term) do
    {:noreply, assign(term, om_active: true)}
  end

  def handle_info({:om_event, {:om, :observation_complete, metadata}}, term) do
    # Extract tokens_produced from metadata and update memory_tokens
    memory_tokens =
      case metadata do
        %{tokens_produced: tokens} -> tokens
        _ -> term.assigns.memory_tokens
      end

    {:noreply,
     assign(term, om_active: false, om_sync_fallback: false, memory_tokens: memory_tokens)}
  end

  def handle_info({:om_event, {:om, :reflection_started, _metadata}}, term) do
    {:noreply, assign(term, om_active: true)}
  end

  def handle_info({:om_event, {:om, :reflection_complete, metadata}}, term) do
    # Extract after_tokens from metadata and update memory_tokens
    memory_tokens =
      case metadata do
        %{after_tokens: tokens} -> tokens
        _ -> term.assigns.memory_tokens
      end

    {:noreply,
     assign(term, om_active: false, om_sync_fallback: false, memory_tokens: memory_tokens)}
  end

  def handle_info({:om_event, {:om, :buffering_started, _metadata}}, term) do
    {:noreply, assign(term, om_active: true)}
  end

  def handle_info({:om_event, {:om, :buffering_complete, _metadata}}, term) do
    {:noreply, assign(term, om_active: false)}
  end

  def handle_info({:om_event, {:om, :sync_fallback, _metadata}}, term) do
    {:noreply, assign(term, om_active: true, om_sync_fallback: true)}
  end

  def handle_info({:om_event, {:om, :activation, _metadata}}, term) do
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

  # Job status broadcasts from Foreman (agent roster updates)
  def handle_info({:job_status, agent_statuses}, term) do
    {:noreply, assign(term, agent_statuses: agent_statuses)}
  end

  # Ignore events that don't need display updates
  def handle_info({:agent_event, {:tool_call_delta, _}}, term), do: {:noreply, term}
  def handle_info({:agent_event, _event}, term), do: {:noreply, term}
  def handle_info({:om_event, _event}, term), do: {:noreply, term}
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

            # Add user message to chat
            user_msg = %{
              role: :user,
              content: text,
              timestamp: DateTime.utc_now()
            }

            # Send prompt to agent
            Deft.Agent.prompt(term.assigns.agent_pid, text)

            # Clear input
            new_term =
              term
              |> assign(messages: term.assigns.messages ++ [user_msg])
              |> assign(input: "")
              |> assign(input_history: history)
              |> assign(input_history_index: nil)
              |> assign(last_char_timestamp: nil)

            {:noreply, new_term}

          {:inject_skill, definition} ->
            # Add to history
            history = [input | term.assigns.input_history]

            # Add system message to chat (so user can see the skill was invoked)
            system_msg = %{
              role: :system,
              content: "[Skill invoked: #{input}]",
              timestamp: DateTime.utc_now()
            }

            # Inject skill as system instruction to agent
            Deft.Agent.inject_skill(term.assigns.agent_pid, definition)

            # Clear input
            new_term =
              term
              |> assign(messages: term.assigns.messages ++ [system_msg])
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
    {:noreply,
     assign(term,
       messages: [],
       current_text: "",
       current_thinking: "",
       completed_thinking_blocks: [],
       had_non_thinking_event: false
     )}
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
      |> assign(had_non_thinking_event: true)
      |> assign(streaming: true)

    {:noreply, new_term}
  end

  defp handle_thinking_delta(delta, term) do
    # If we had tool or text events since the last thinking block,
    # commit the current thinking block and start a new one
    {new_completed_blocks, new_current_thinking} =
      if term.assigns.had_non_thinking_event and term.assigns.current_thinking != "" do
        # Commit current thinking block and start new one
        {term.assigns.completed_thinking_blocks ++ [term.assigns.current_thinking], delta}
      else
        # Continue current thinking block
        {term.assigns.completed_thinking_blocks, term.assigns.current_thinking <> delta}
      end

    new_term =
      term
      |> assign(current_thinking: new_current_thinking)
      |> assign(completed_thinking_blocks: new_completed_blocks)
      |> assign(had_non_thinking_event: false)
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

        new_term =
          term
          |> assign(active_tools: new_active_tools)
          |> assign(had_non_thinking_event: true)

        {:noreply, new_term}
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
      |> assign(current_thinking: "")
      |> assign(completed_thinking_blocks: [])
      |> assign(had_non_thinking_event: false)

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
      |> assign(current_thinking: "")
      |> assign(completed_thinking_blocks: [])
      |> assign(had_non_thinking_event: false)
      |> assign(active_tools: %{})

    {:noreply, new_term}
  end

  defp commit_streaming_message(term) do
    if term.assigns.current_text != "" do
      # Collect all thinking blocks (completed + current)
      all_thinking_blocks =
        if term.assigns.current_thinking != "" do
          term.assigns.completed_thinking_blocks ++ [term.assigns.current_thinking]
        else
          term.assigns.completed_thinking_blocks
        end

      # Create assistant message with the accumulated text and thinking blocks
      message = %{
        role: :assistant,
        content: term.assigns.current_text,
        thinking_blocks: all_thinking_blocks,
        timestamp: DateTime.utc_now()
      }

      term
      |> assign(messages: term.assigns.messages ++ [message])
      |> assign(current_text: "")
      |> assign(current_thinking: "")
      |> assign(completed_thinking_blocks: [])
      |> assign(had_non_thinking_event: false)
      |> assign(streaming: false)
      |> assign(active_tools: %{})
    else
      term
      |> assign(streaming: false)
      |> assign(current_thinking: "")
      |> assign(completed_thinking_blocks: [])
      |> assign(had_non_thinking_event: false)
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
        new_term =
          assign(term,
            messages: [],
            current_text: "",
            current_thinking: "",
            completed_thinking_blocks: [],
            had_non_thinking_event: false
          )

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

      # Handle /correct command for job corrections
      String.starts_with?(input, "/correct ") ->
        handle_correct_command(input, term)

      # Other slash commands are dispatched via SlashCommand module
      String.starts_with?(input, "/") ->
        handle_slash_command(input, term)

      # Regular text - submit to agent
      true ->
        {:submit, input}
    end
  end

  defp show_command_error(term, content) do
    error_msg = %{
      role: :system,
      content: content,
      timestamp: DateTime.utc_now()
    }

    new_term = assign(term, messages: term.assigns.messages ++ [error_msg])
    {:command_handled, new_term}
  end

  defp handle_command_dispatch(name, args, term) do
    case SlashCommand.dispatch(name) do
      {:ok, :command, definition} ->
        # Commands are injected as user messages
        # Combine the definition with args for context
        full_text = if args != "", do: "#{definition}\n\nArgs: #{args}", else: definition
        {:submit, full_text}

      {:ok, :skill, definition} ->
        # Skills must be injected as system instructions per spec section 2.4
        # Combine the definition with args for context
        full_text = if args != "", do: "#{definition}\n\nArgs: #{args}", else: definition
        {:inject_skill, full_text}

      {:error, :not_found, command_name} ->
        show_command_error(term, "Unknown command: /#{command_name}")

      {:error, :no_definition, command_name} ->
        show_command_error(term, "Command /#{command_name} exists but has no definition")

      {:error, reason, command_name} ->
        show_command_error(term, "Error loading command /#{command_name}: #{reason}")
    end
  end

  defp handle_slash_command(input, term) do
    case SlashCommand.parse(input) do
      {:command, name, args} ->
        handle_command_dispatch(name, args, term)

      {:not_slash, text} ->
        # This shouldn't happen since we already checked for "/" prefix
        {:submit, text}
    end
  end

  defp handle_correct_command(input, term) do
    # Extract message from `/correct <message>`
    message = String.slice(input, 9..-1//1)

    # Check if this is a job correction (no → separator) and job is active
    # Job corrections get the __JOB_CORRECTION__ prefix for the Foreman
    # OM corrections (with →) go through the normal command dispatch
    if term.assigns.job_active and not String.contains?(message, "→") do
      # Job correction - add sentinel prefix and submit to Foreman
      corrected_text = "__JOB_CORRECTION__: " <> message
      {:submit, corrected_text}
    else
      # OM correction or no job active - use regular slash command dispatch
      handle_slash_command(input, term)
    end
  end

  # Rendering helpers

  defp calculate_streaming_rendered(assigns) do
    thinking_part = render_all_thinking_blocks(assigns)
    text_part = render_streaming_text(assigns)

    combine_rendered_parts(thinking_part, text_part)
  end

  defp render_all_thinking_blocks(assigns) do
    # Render all completed thinking blocks
    completed =
      assigns.completed_thinking_blocks
      |> Enum.map(&render_thinking_block/1)
      |> Enum.join("\n\n")

    # Render current thinking block
    current = render_thinking_block(assigns.current_thinking)

    combine_rendered_parts(completed, current)
  end

  defp render_streaming_text(assigns) do
    if assigns.streaming and assigns.current_text != "" do
      if assigns.raw_mode do
        assigns.current_text
      else
        {rendered, _buffer} = Markdown.render_streaming(assigns.current_text)
        rendered
      end
    else
      ""
    end
  end

  defp combine_rendered_parts("", ""), do: ""
  defp combine_rendered_parts(part1, ""), do: part1
  defp combine_rendered_parts("", part2), do: part2
  defp combine_rendered_parts(part1, part2), do: part1 <> "\n\n" <> part2

  defp render_thinking_block(""), do: ""

  defp render_thinking_block(thinking) do
    # Split thinking into lines for proper formatting
    lines = String.split(thinking, "\n")

    # Render with dim + italic ANSI styling
    # \e[2m = dim, \e[3m = italic
    # \e[22m = reset dim, \e[23m = reset italic
    formatted_lines =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        if index == 0 do
          "[thinking: " <> line
        else
          " " <> line
        end
      end)

    content = Enum.join(formatted_lines, "\n")
    "\e[2m\e[3m" <> content <> "]" <> "\e[23m\e[22m"
  end

  defp calculate_visible_messages(assigns) do
    # Apply scroll offset to determine which messages are visible
    # scroll_offset = 0: show all messages (default, no scrolling)
    # scroll_offset > 0: scrolled up, skip the most recent messages

    if assigns.scroll_offset > 0 do
      # Approximate line count per message (user/assistant label + content ≈ 3-5 lines)
      # Using 3 as a conservative estimate
      messages_to_skip = div(assigns.scroll_offset, 3)
      message_count = length(assigns.messages)

      if messages_to_skip >= message_count do
        # Scrolled past all messages, show empty or first message
        Enum.take(assigns.messages, 1)
      else
        # Drop the most recent N messages to show older content
        Enum.drop(assigns.messages, -messages_to_skip)
      end
    else
      # No scrolling, show all messages
      assigns.messages
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

  defp render_message(%{role: :assistant, content: content} = message, raw_mode) do
    # Render thinking blocks if present
    thinking_blocks = Map.get(message, :thinking_blocks, [])

    thinking_rendered =
      thinking_blocks
      |> Enum.map(&render_thinking_block/1)
      |> Enum.join("\n\n")

    # Render markdown for assistant messages unless raw_mode is enabled
    content_rendered = if raw_mode, do: content, else: Markdown.render(content)

    # Combine thinking blocks and content
    full_content =
      case {thinking_rendered, content_rendered} do
        {"", text} -> text
        {thinking, ""} -> thinking
        {thinking, text} -> thinking <> "\n\n" <> text
      end

    assigns = %{content: full_content}

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

    model = config[:model] || "claude-sonnet-4-20250514"

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

  # Extract repo name from working directory
  # Resolves to git root if in a git repo, then takes basename and truncates to 20 chars
  defp extract_repo_name(working_dir) do
    repo_root = resolve_git_root(working_dir)
    basename = Path.basename(repo_root)

    if String.length(basename) > 20 do
      String.slice(basename, 0, 19) <> "…"
    else
      basename
    end
  end

  # Resolve to git repository root if inside a git repo
  defp resolve_git_root(path) do
    case System.cmd("git", ["rev-parse", "--git-common-dir"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> then(&Path.expand(&1, path))
        |> Path.dirname()

      {_output, _exit_code} ->
        # Not a git repo, use the path as-is
        path
    end
  end

  # Render agent roster (orchestration mode only)
  # Returns a list of right-aligned text rows showing agent status
  defp render_agent_roster(agent_statuses, terminal_width \\ 80) when is_list(agent_statuses) do
    if length(agent_statuses) == 0 do
      []
    else
      # Group by type to collapse multiple Runners
      {runners, non_runners} =
        Enum.split_with(agent_statuses, fn status ->
          Map.get(status, :type) == :runner
        end)

      # Collapse multiple runners into a single entry
      collapsed_statuses =
        case runners do
          [] ->
            non_runners

          [single_runner] ->
            # Single runner, show as-is
            non_runners ++ [single_runner]

          multiple_runners ->
            # Multiple runners, collapse into "Runners (N)"
            runner_count = length(multiple_runners)
            # Use the first runner's state as representative
            first_runner_state = Map.get(hd(multiple_runners), :state, :idle)

            collapsed_runner = %{
              id: "runners",
              type: :runner,
              state: first_runner_state,
              label: "Runners (#{runner_count})"
            }

            non_runners ++ [collapsed_runner]
        end

      # Format each agent as "Label  ◉ state"
      collapsed_statuses
      |> Enum.map(fn status ->
        label = Map.get(status, :label, "Unknown")
        state = Map.get(status, :state, :idle)
        state_text = format_agent_roster_state(state)

        # Build the roster line: "Label  ◉ state"
        roster_line = "#{label}  #{state_text}"

        # Right-align by padding with spaces
        # Roster occupies rightmost ~30 columns
        line_length = String.length(roster_line)
        padding = max(0, terminal_width - line_length - 1)

        String.duplicate(" ", padding) <> roster_line
      end)
    end
  end

  # Format agent state with colored indicator for roster display
  defp format_agent_roster_state(state) do
    indicator = colorize_state_indicator(state)
    "#{indicator} #{state}"
  end

  # Colorize the ◉ indicator based on agent state
  defp colorize_state_indicator(state)
       when state in [
              :planning,
              :researching,
              :executing,
              :implementing,
              :testing,
              :merging,
              :verifying
            ] do
    # Green for active states
    "\e[32m◉\e[39m"
  end

  defp colorize_state_indicator(:waiting) do
    # Yellow for waiting
    "\e[33m◉\e[39m"
  end

  defp colorize_state_indicator(:error) do
    # Red for error
    "\e[31m◉\e[39m"
  end

  defp colorize_state_indicator(_) do
    # White for idle/complete/other
    "\e[37m◉\e[39m"
  end
end
