defmodule DeftWeb.SessionsLive do
  @moduledoc """
  Session picker LiveView.

  Lists available sessions with metadata, sorted most-recent-first.
  Supports vim-style keyboard navigation (j/k to move, Enter to select).
  """

  use DeftWeb, :live_view

  alias Deft.Session.Store

  @impl true
  def mount(_params, _session, socket) do
    # Load sessions from store
    {:ok, sessions} = Store.list()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:selected_index, 0)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sessions-picker" phx-window-keydown="keydown">
      <header class="header">
        <h1>Sessions</h1>
        <p class="help-text">j/k to navigate • Enter to select • q to quit</p>
      </header>

      <div class="sessions-list">
        <%= for {session, index} <- Enum.with_index(@sessions) do %>
          <div class={"session-item #{if index == @selected_index, do: "selected", else: ""}"}>
            <div class="session-header">
              <span class="session-id"><%= session.session_id %></span>
              <span class="session-date"><%= format_datetime(session.last_message_at) %></span>
            </div>
            <div class="session-details">
              <span class="working-dir"><%= session.working_dir %></span>
              <span class="message-count"><%= session.message_count %> messages</span>
            </div>
            <%= if session.last_user_prompt != "" do %>
              <div class="last-prompt"><%= session.last_user_prompt %></div>
            <% end %>
          </div>
        <% end %>

        <%= if @sessions == [] do %>
          <div class="empty-state">
            <p>No sessions found.</p>
            <p class="help-text">Start a new session with <code>deft</code>.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("keydown", %{"key" => "j"}, socket) do
    # Move down
    max_index = length(socket.assigns.sessions) - 1
    new_index = min(socket.assigns.selected_index + 1, max_index)
    {:noreply, assign(socket, :selected_index, new_index)}
  end

  def handle_event("keydown", %{"key" => "k"}, socket) do
    # Move up
    new_index = max(socket.assigns.selected_index - 1, 0)
    {:noreply, assign(socket, :selected_index, new_index)}
  end

  def handle_event("keydown", %{"key" => "Enter"}, socket) do
    # Select current session
    sessions = socket.assigns.sessions
    selected_index = socket.assigns.selected_index

    if selected_index < length(sessions) do
      session = Enum.at(sessions, selected_index)
      {:noreply, push_navigate(socket, to: "/?session=#{session.session_id}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("keydown", %{"key" => "q"}, socket) do
    # Quit - go back to current session or close
    {:noreply, push_navigate(socket, to: "/")}
  end

  def handle_event("keydown", _params, socket) do
    # Ignore other keys
    {:noreply, socket}
  end

  # Private helpers

  defp format_datetime(nil), do: "—"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end
end
