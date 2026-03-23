defmodule Deft.TUI.SessionPicker do
  @moduledoc """
  Session picker view for resuming previous Deft sessions.

  Lists all available sessions from `Deft.Session.Store.list/0` and allows
  the user to navigate with arrow keys and select with Enter to resume.

  ## Display Format

  Shows session ID, working directory, last activity timestamp, and message count.
  Sorted most-recent-first.

  ## Keyboard Navigation

  - Up/Down arrows: navigate between sessions
  - Enter: select and resume the highlighted session
  - Ctrl+C / Ctrl+D: quit without resuming
  - q: quit without resuming
  """

  use Breeze.View

  alias Deft.Session.Store

  @doc """
  Mounts the session picker view.

  Loads all sessions from the session store and initializes navigation state.

  ## Parameters

  - `params` - Map containing:
    - `:on_select` - Optional callback function `(session_id -> :ok)` to invoke when a session is selected
  - `term` - The Breeze terminal state
  """
  def mount(params, term) do
    # Load sessions from store
    working_dir = Map.get(params, :working_dir, File.cwd!())

    sessions =
      case Store.list(working_dir) do
        {:ok, sessions} -> sessions
        {:error, _reason} -> []
      end

    on_select = Map.get(params, :on_select)

    term =
      term
      |> assign(
        sessions: sessions,
        selected_index: 0,
        on_select: on_select
      )

    {:ok, term}
  end

  @doc """
  Renders the session picker view.

  Layout:
  - Header with title
  - List of sessions (scrollable) with current selection highlighted
  - Footer with keyboard shortcuts
  """
  def render(assigns) do
    assigns =
      assign(assigns,
        has_sessions?: length(assigns.sessions) > 0
      )

    ~H"""
    <box>
      <box style="bold border">Deft - Session Picker</box>

      <box style="border height-20">
        <%= if @has_sessions? do %>
          <%= for {session, index} <- Enum.with_index(@sessions) do %>
            <%= render_session(session, index, @selected_index) %>
          <% end %>
        <% else %>
          <box style="dim">No previous sessions found.</box>
          <box style="dim">Start a new session to begin.</box>
        <% end %>
      </box>

      <box style="border">
        <box style="dim">
          <%= if @has_sessions? do %>
            Up/Down: navigate | Enter: resume | q/Ctrl+C: quit
          <% else %>
            Press q or Ctrl+C to quit
          <% end %>
        </box>
      </box>
    </box>
    """
  end

  @doc """
  Handles keyboard input events.

  - Up arrow: move selection up
  - Down arrow: move selection down
  - Enter: resume selected session
  - q / Ctrl+C / Ctrl+D: quit without resuming
  """
  def handle_event(_event, %{"key" => "up"}, term) do
    handle_navigation(:up, term)
  end

  def handle_event(_event, %{"key" => "down"}, term) do
    handle_navigation(:down, term)
  end

  def handle_event(_event, %{"key" => "enter"}, term) do
    handle_select(term)
  end

  def handle_event(_event, %{"key" => key}, term) when key in ["q", "ctrl-c", "ctrl-d"] do
    {:stop, term}
  end

  def handle_event(_event, _params, term) do
    {:noreply, term}
  end

  # Private functions

  defp handle_navigation(:up, term) do
    sessions = term.assigns.sessions
    current_index = term.assigns.selected_index

    if length(sessions) > 0 do
      new_index = max(0, current_index - 1)
      {:noreply, assign(term, selected_index: new_index)}
    else
      {:noreply, term}
    end
  end

  defp handle_navigation(:down, term) do
    sessions = term.assigns.sessions
    current_index = term.assigns.selected_index

    if length(sessions) > 0 do
      new_index = min(length(sessions) - 1, current_index + 1)
      {:noreply, assign(term, selected_index: new_index)}
    else
      {:noreply, term}
    end
  end

  defp handle_select(term) do
    sessions = term.assigns.sessions
    selected_index = term.assigns.selected_index

    if length(sessions) > 0 do
      selected_session = Enum.at(sessions, selected_index)

      # Invoke callback if provided (callback should send to CLI process)
      if term.assigns.on_select do
        term.assigns.on_select.(selected_session.session_id)
      end

      # Stop the picker view - callback already notified CLI
      {:stop, term}
    else
      {:noreply, term}
    end
  end

  # Rendering helpers

  defp render_session(session, index, selected_index) do
    selected? = index == selected_index

    # Format timestamp
    timestamp_str = format_timestamp(session.last_message_at)

    # Format working directory (truncate if too long)
    working_dir = format_working_dir(session.working_dir)

    # Format last user prompt (truncate if too long)
    last_prompt = format_last_prompt(session.last_user_prompt)

    # Build the session line
    session_line = build_session_line(session, working_dir, timestamp_str, last_prompt)

    assigns = %{
      selected?: selected?,
      session_line: session_line
    }

    ~H"""
    <box>
      <%= if @selected? do %>
        <box style="bold reverse"><%= @session_line %></box>
      <% else %>
        <box><%= @session_line %></box>
      <% end %>
    </box>
    """
  end

  defp build_session_line(session, working_dir, timestamp_str, last_prompt) do
    # Format: [session_id] working_dir | timestamp | N messages | last prompt
    session_id_short = String.slice(session.session_id, 0..7)

    if last_prompt != "" do
      "[#{session_id_short}] #{working_dir} | #{timestamp_str} | #{session.message_count} msgs | #{last_prompt}"
    else
      "[#{session_id_short}] #{working_dir} | #{timestamp_str} | #{session.message_count} msgs"
    end
  end

  defp format_timestamp(timestamp) do
    # Format as relative time (e.g., "2h ago", "3d ago")
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, timestamp, :second)

    cond do
      diff_seconds < 60 ->
        "#{diff_seconds}s ago"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes}m ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours}h ago"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86400)
        "#{days}d ago"

      true ->
        # For older sessions, show the date
        Calendar.strftime(timestamp, "%Y-%m-%d")
    end
  end

  defp format_working_dir(path) do
    # Abbreviate home directory and truncate if needed
    abbreviated =
      case System.get_env("HOME") do
        nil -> path
        home -> String.replace(path, home, "~")
      end

    # Truncate to max 30 chars
    if String.length(abbreviated) > 30 do
      String.slice(abbreviated, 0..29) <> "…"
    else
      abbreviated
    end
  end

  defp format_last_prompt(prompt) do
    # Truncate to max 40 chars
    if String.length(prompt) > 40 do
      String.slice(prompt, 0..39) <> "…"
    else
      prompt
    end
  end
end
