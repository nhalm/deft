defmodule DeftWeb.Components.Thinking do
  @moduledoc """
  Function component for rendering thinking blocks.

  Displays thinking blocks with:
  - Gray background and italic text
  - "thinking:" label prefix
  - Collapsible with phx-click toggle (default expanded)
  """

  use Phoenix.Component

  @doc """
  Renders a thinking block with collapsible content.

  ## Attributes

  - `id` - Unique identifier for the thinking block (required)
  - `content` - The thinking text content (required)
  - `expanded` - Whether the block is expanded (default: true)

  ## Examples

      <.thinking id="thinking-1" content="analyzing the auth module..." />
      <.thinking id="thinking-2" content="considering alternatives..." expanded={false} />
  """
  attr(:id, :string, required: true)
  attr(:content, :string, required: true)
  attr(:expanded, :boolean, default: true)

  def thinking(assigns) do
    ~H"""
    <div
      id={@id}
      class="thinking-block"
      phx-click="toggle_thinking"
      phx-value-id={@id}
      style="
        background-color: #2a2a2a;
        color: #a0a0a0;
        padding: 8px 12px;
        margin: 8px 0;
        border-radius: 4px;
        font-style: italic;
        cursor: pointer;
        user-select: none;
      "
    >
      <div class="thinking-header" style="font-weight: 500;">
        <span style="margin-right: 8px;"><%= if @expanded, do: "▼", else: "▶" %></span>
        <span>thinking:</span>
      </div>
      <div
        class="thinking-content"
        style={"
          margin-top: 4px;
          margin-left: 24px;
          #{unless @expanded, do: "display: none;", else: ""}
        "}
      >
        <%= @content %>
      </div>
    </div>
    """
  end
end
