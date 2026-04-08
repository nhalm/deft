defmodule DeftWeb.Components.ToolCall do
  @moduledoc """
  Function component for rendering tool execution display.

  Tool cards render compact. Details are fetched on click via plain HTTP.
  """

  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:key_arg, :string, default: nil)
  attr(:status, :atom, default: :running)
  attr(:duration, :float, default: nil)
  attr(:session_id, :string, default: nil)
  attr(:tool_call_id, :string, default: nil)

  def tool_call(assigns) do
    assigns = assign(assigns, :border_color, status_color(assigns.status))

    ~H"""
    <div id={@id} class="tool-call" style={"border-left: 3px solid #{@border_color};"} data-session-id={@session_id} data-tool-call-id={@tool_call_id}>
      <div class="tool-header" onclick={"window.toggleToolDetail('#{@id}')"}>
        <%= status_icon(@status) %>
        <span class="tool-name">[Tool: <%= @name %>]</span>
        <%= if @key_arg do %>
          <span class="tool-arg"><%= @key_arg %></span>
        <% end %>
        <%= if @status != :running && @duration do %>
          <span class="tool-duration"><%= format_duration(@duration) %></span>
        <% end %>
        <span class="tool-toggle-icon">▶</span>
      </div>
      <div id={"#{@id}-details"} class="tool-details hidden"></div>
    </div>
    """
  end

  defp status_color(:running), do: "#3b82f6"
  defp status_color(:success), do: "#10b981"
  defp status_color(:error), do: "#ef4444"
  defp status_color(_), do: "#6b7280"

  defp status_icon(:running) do
    assigns = %{}

    ~H"""
    <span class="spinner" style="display:inline-block;width:12px;height:12px;border:2px solid #3b82f6;border-top-color:transparent;border-radius:50%;animation:spin 1s linear infinite;"></span>
    """
  end

  defp status_icon(:success) do
    assigns = %{}

    ~H"""
    <span style="color: #10b981; font-weight: bold;">✓</span>
    """
  end

  defp status_icon(:error) do
    assigns = %{}

    ~H"""
    <span style="color: #ef4444; font-weight: bold;">✗</span>
    """
  end

  defp status_icon(_status) do
    assigns = %{}

    ~H"""
    <span style="color: #6b7280;">○</span>
    """
  end

  defp format_duration(nil), do: ""

  defp format_duration(duration) when is_float(duration) do
    if duration < 1.0 do
      "#{trunc(duration * 1000)}ms"
    else
      "#{Float.round(duration, 1)}s"
    end
  end

  defp format_duration(duration) when is_integer(duration) do
    if duration < 1000 do
      "#{duration}ms"
    else
      "#{Float.round(duration / 1000, 1)}s"
    end
  end
end
