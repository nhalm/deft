defmodule DeftWeb.Components.Roster do
  @moduledoc """
  Function component for rendering the agent roster sidebar.

  Displays all agents during orchestration with:
  - Agent name and colored status dot
  - State label
  - CSS transition for show/hide
  - Hidden in solo mode
  """

  use Phoenix.Component

  @doc """
  Renders the agent roster sidebar with status indicators.

  ## Attributes

  - `agents` - List of agent maps with :label and :state keys (required)
  - `visible` - Whether the roster is visible (default: false, hidden in solo mode)

  ## Examples

      <.roster agents={[]} visible={false} />

      <.roster
        agents={[
          %{label: "Foreman", state: :executing},
          %{label: "Lead A", state: :implementing},
          %{label: "Lead B", state: :waiting}
        ]}
        visible={true}
      />
  """
  attr(:agents, :list, default: [])
  attr(:visible, :boolean, default: false)

  def roster(assigns) do
    ~H"""
    <div
      class="roster-panel"
      style={"
        background-color: #1a1a1a;
        border-left: 1px solid #333;
        padding: 16px;
        min-width: 180px;
        max-width: 240px;
        overflow-y: auto;
        transition: transform 0.3s ease-in-out, opacity 0.3s ease-in-out;
        #{unless @visible, do: "transform: translateX(100%); opacity: 0; position: absolute; pointer-events: none;", else: "transform: translateX(0); opacity: 1;"}
      "}
    >
      <div style="
        font-weight: 600;
        font-size: 0.9em;
        color: #e0e0e0;
        margin-bottom: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      ">
        Agents
      </div>

      <%= if @agents == [] do %>
        <div style="color: #666; font-size: 0.85em; font-style: italic;">
          No agents running
        </div>
      <% else %>
        <div class="agent-list" style="display: flex; flex-direction: column; gap: 8px;">
          <%= for agent <- @agents do %>
            <div
              class="agent-item"
              style="
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 8px;
                border-radius: 4px;
                background-color: #222;
                transition: background-color 0.2s;
                cursor: pointer;
              "
            >
              <span style={"
                display: inline-block;
                width: 8px;
                height: 8px;
                border-radius: 50%;
                background-color: #{state_color(agent.state)};
                flex-shrink: 0;
              "}>
              </span>
              <div style="flex: 1; min-width: 0;">
                <div style="
                  font-size: 0.9em;
                  color: #e0e0e0;
                  font-weight: 500;
                  white-space: nowrap;
                  overflow: hidden;
                  text-overflow: ellipsis;
                ">
                  <%= agent.label %>
                </div>
                <div style="
                  font-size: 0.75em;
                  color: #{state_color(agent.state)};
                  text-transform: lowercase;
                ">
                  <%= agent.state %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Private helpers

  defp state_color(:executing), do: "#10b981"
  defp state_color(:implementing), do: "#10b981"
  defp state_color(:active), do: "#10b981"
  defp state_color(:waiting), do: "#eab308"
  defp state_color(:idle), do: "#6b7280"
  defp state_color(:complete), do: "#6b7280"
  defp state_color(:error), do: "#ef4444"
  defp state_color(_), do: "#a0a0a0"
end
