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
        # Scroll state
        scroll_offset: 0
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
        agent_state_display: format_agent_state(assigns.agent_state, assigns.om_active)
      )

    ~H"""
    <box>
      <box style="bold border">Deft - <%= @model_name %></box>

      <box style="border height-20">
        <%= for message <- @messages do %>
          <%= render_message(message) %>
        <% end %>
        <%= if @streaming and @current_text != "" do %>
          <box><%= @current_text %></box>
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
          <%= format_tokens(@current_tokens, @context_window) %> │
          <%= format_memory(@memory_tokens, @memory_threshold) %> │
          <%= format_cost(@session_cost) %> │
          turn <%= @turn_count %>/<%= @max_turns %> │
          <%= @agent_state_display %>
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

  # Ignore events that don't need display updates
  def handle_info({:agent_event, {:thinking_delta, _delta}}, term), do: {:noreply, term}
  def handle_info({:agent_event, {:tool_call_delta, _}}, term), do: {:noreply, term}
  def handle_info({:agent_event, _event}, term), do: {:noreply, term}

  def handle_info(_msg, term) do
    {:noreply, term}
  end

  @doc """
  Handles keyboard input events.

  - Enter: submit prompt
  - Ctrl+C / Ctrl+D: quit
  - Ctrl+L: clear screen
  - Up/Down: input history navigation
  """
  def handle_event(_event, %{"key" => "enter"}, term) do
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

          {:noreply, new_term}

        {:command_handled, new_term} ->
          # Command was handled, clear input
          history = [input | term.assigns.input_history]

          new_term =
            new_term
            |> assign(input: "")
            |> assign(input_history: history)
            |> assign(input_history_index: nil)

          {:noreply, new_term}
      end
    else
      {:noreply, term}
    end
  end

  def handle_event(_event, %{"key" => key}, term) when key in ["ctrl-c", "ctrl-d"] do
    # Quit the application
    {:stop, term}
  end

  def handle_event(_event, %{"key" => "ctrl-l"}, term) do
    # Clear screen - reset messages
    {:noreply, assign(term, messages: [], current_text: "")}
  end

  def handle_event(_event, %{"key" => "up"}, term) do
    # Navigate input history - previous entry
    handle_history_navigation(:prev, term)
  end

  def handle_event(_event, %{"key" => "down"}, term) do
    # Navigate input history - next entry
    handle_history_navigation(:next, term)
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

  def handle_event(_event, %{"key" => key}, term) do
    # Regular character input - append to input buffer
    # Filter out control characters
    if String.printable?(key) and String.length(key) == 1 do
      new_input = term.assigns.input <> key
      {:noreply, assign(term, input: new_input)}
    else
      {:noreply, term}
    end
  end

  def handle_event(_event, _params, term) do
    {:noreply, term}
  end

  # Private functions

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
        send(self(), {:stop, term})
        {:command_handled, term}

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

      # Other slash commands are dispatched via SlashCommand module
      String.starts_with?(input, "/") ->
        # TODO: Implement slash command dispatch
        # For now, pass through to agent
        {:submit, input}

      # Regular text - submit to agent
      true ->
        {:submit, input}
    end
  end

  # Rendering helpers

  defp render_message(%{role: :user, content: content}) do
    assigns = %{content: content}

    ~H"""
    <box>
      <box style="bold">User:</box>
      <box><%= @content %></box>
    </box>
    """
  end

  defp render_message(%{role: :assistant, content: content}) do
    # Render markdown for assistant messages
    rendered = Markdown.render(content)
    assigns = %{content: rendered}

    ~H"""
    <box>
      <box style="bold">Assistant:</box>
      <box><%= @content %></box>
    </box>
    """
  end

  defp render_message(%{role: :system, content: content}) do
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

  defp format_agent_state(:idle, false), do: "○ idle"
  defp format_agent_state(:idle, true), do: "○ idle"
  defp format_agent_state(:calling, false), do: "◉ calling"
  defp format_agent_state(:calling, true), do: "◉ calling"
  defp format_agent_state(:streaming, false), do: "◉ streaming"
  defp format_agent_state(:streaming, true), do: "◉ streaming"
  defp format_agent_state(:executing_tools, false), do: "◉ tools"
  defp format_agent_state(:executing_tools, true), do: "◉ tools"
  defp format_agent_state(state, _om_active), do: "◉ #{state}"

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
    Ctrl+C/Ctrl+D - Exit
    Ctrl+L        - Clear screen
    Up/Down       - Navigate input history
    """
  end
end
