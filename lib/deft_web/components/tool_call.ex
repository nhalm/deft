defmodule DeftWeb.Components.ToolCall do
  @moduledoc """
  Function component for rendering tool execution display.

  Displays tool calls with:
  - Tool name and key argument
  - CSS spinner animation while running
  - ✓/✗ icon and duration on completion
  - Expandable detail (click to see full tool input/output)
  """

  use Phoenix.Component

  @doc """
  Renders a tool call with status indicator and expandable details.

  ## Attributes

  - `id` - Unique identifier for the tool call (required)
  - `name` - Tool name (required)
  - `key_arg` - Key argument to display (optional)
  - `status` - Tool status: :running, :success, :error (default: :running)
  - `duration` - Execution duration in seconds (optional, shown when complete)
  - `input` - Full tool input for expanded view (optional)
  - `output` - Full tool output for expanded view (optional)
  - `expanded` - Whether details are expanded (default: false)

  ## Examples

      <.tool_call id="tool-1" name="read" key_arg="src/auth.ex" status={:running} />
      <.tool_call id="tool-2" name="bash" key_arg="mix test" status={:success} duration={3.2} />
      <.tool_call id="tool-3" name="edit" key_arg="config.ex" status={:error} duration={0.5} expanded={true} />
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:key_arg, :string, default: nil)
  attr(:status, :atom, default: :running)
  attr(:duration, :float, default: nil)
  attr(:input, :string, default: nil)
  attr(:output, :string, default: nil)
  attr(:expanded, :boolean, default: false)

  def tool_call(assigns) do
    assigns = assign(assigns, :border_color, status_color(assigns.status))

    ~H"""
    <div
      id={@id}
      class="tool-call"
      phx-click="toggle_tool"
      phx-value-id={@id}
      style={"
        background-color: #1a1a1a;
        border-left: 3px solid #{@border_color};
        padding: 8px 12px;
        margin: 8px 0;
        border-radius: 4px;
        cursor: pointer;
        user-select: none;
      "}
    >
      <div class="tool-header" style="display: flex; align-items: center; gap: 8px;">
        <%= status_icon(@status) %>
        <span style="font-weight: 500; color: #e0e0e0;">
          [Tool: <%= @name %>]
        </span>
        <%= if @key_arg do %>
          <span style="color: #a0a0a0;"><%= @key_arg %></span>
        <% end %>
        <%= if @status != :running && @duration do %>
          <span style="color: #808080; margin-left: auto;">
            <%= format_duration(@duration) %>
          </span>
        <% end %>
        <%= if @expanded do %>
          <span style="margin-left: auto; color: #606060;">▼</span>
        <% else %>
          <span style="margin-left: auto; color: #606060;">▶</span>
        <% end %>
      </div>

      <%= if @expanded && (@input || @output) do %>
        <div
          class="tool-details"
          style="
            margin-top: 8px;
            padding-top: 8px;
            border-top: 1px solid #333;
            font-size: 0.9em;
          "
        >
          <%= if @input do %>
            <div style="margin-bottom: 8px;">
              <div style="color: #808080; font-weight: 500; margin-bottom: 4px;">Input:</div>
              <pre style="
                background-color: #0d0d0d;
                padding: 8px;
                border-radius: 3px;
                overflow-x: auto;
                margin: 0;
                color: #c0c0c0;
              "><%= @input %></pre>
            </div>
          <% end %>

          <%= if @output do %>
            <div>
              <div style="color: #808080; font-weight: 500; margin-bottom: 4px;">Output:</div>
              <pre style="
                background-color: #0d0d0d;
                padding: 8px;
                border-radius: 3px;
                overflow-x: auto;
                margin: 0;
                color: #c0c0c0;
              "><%= @output %></pre>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Private helpers

  defp status_color(:running), do: "#3b82f6"
  defp status_color(:success), do: "#10b981"
  defp status_color(:error), do: "#ef4444"
  defp status_color(_), do: "#6b7280"

  defp status_icon(:running) do
    assigns = %{}

    ~H"""
    <span
      class="spinner"
      style="
        display: inline-block;
        width: 12px;
        height: 12px;
        border: 2px solid #3b82f6;
        border-top-color: transparent;
        border-radius: 50%;
        animation: spin 1s linear infinite;
      "
    >
    </span>
    <style>
      @keyframes spin {
        to { transform: rotate(360deg); }
      }
    </style>
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
