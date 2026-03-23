defmodule DeftWeb.Components.StatusBar do
  @moduledoc """
  Function component for rendering the status bar.

  Displays status information at the bottom of the interface:
  - Solo mode: tokens, memory, cost, turn count, agent state
  - Orchestration mode: lead count, completion status, cost, elapsed time, agent state
  """

  use Phoenix.Component

  @doc """
  Renders a status bar with mode-specific information.

  ## Attributes

  ### Common attributes
  - `mode` - Display mode: :solo or :orchestration (default: :solo)
  - `state` - Agent state atom (e.g., :idle, :executing, :waiting)

  ### Solo mode attributes
  - `tokens_used` - Total tokens consumed (input + output)
  - `tokens_max` - Maximum token limit (default: 200_000)
  - `memory_tokens` - Observational memory token count
  - `memory_max` - Maximum memory tokens (default: 40_000)
  - `cost` - Total cost in dollars
  - `turn` - Current turn number
  - `turn_limit` - Maximum turns (default: 25)

  ### Orchestration mode attributes
  - `lead_count` - Number of lead agents
  - `completed` - Number of completed leads
  - `total` - Total number of leads
  - `cost` - Cost consumed in dollars
  - `cost_limit` - Maximum cost budget
  - `elapsed_seconds` - Elapsed time in seconds

  ## Examples

      # Solo mode
      <.status_bar
        mode={:solo}
        tokens_used={12400}
        tokens_max={200000}
        memory_tokens={3200}
        memory_max={40000}
        cost={0.42}
        turn={3}
        turn_limit={25}
        state={:idle}
      />

      # Orchestration mode
      <.status_bar
        mode={:orchestration}
        lead_count={2}
        completed={1}
        total={2}
        cost={1.24}
        cost_limit={10.0}
        elapsed_seconds={240}
        state={:executing}
      />
  """
  attr(:mode, :atom, default: :solo)
  attr(:state, :atom, required: true)

  # Solo mode attributes
  attr(:tokens_used, :integer, default: 0)
  attr(:tokens_max, :integer, default: 200_000)
  attr(:memory_tokens, :integer, default: 0)
  attr(:memory_max, :integer, default: 40_000)
  attr(:cost, :float, default: 0.0)
  attr(:turn, :integer, default: 0)
  attr(:turn_limit, :integer, default: 25)

  # Orchestration mode attributes
  attr(:lead_count, :integer, default: 0)
  attr(:completed, :integer, default: 0)
  attr(:total, :integer, default: 0)
  attr(:cost_limit, :float, default: 10.0)
  attr(:elapsed_seconds, :integer, default: 0)

  def status_bar(assigns) do
    ~H"""
    <div
      class="status-bar"
      style="
        background-color: #1a1a1a;
        border-top: 1px solid #333;
        padding: 8px 16px;
        font-size: 0.9em;
        color: #a0a0a0;
        display: flex;
        align-items: center;
        gap: 16px;
        font-family: monospace;
      "
    >
      <%= if @mode == :solo do %>
        <%= render_solo_status(assigns) %>
      <% else %>
        <%= render_orchestration_status(assigns) %>
      <% end %>
    </div>
    """
  end

  # Private helpers

  defp render_solo_status(assigns) do
    ~H"""
    <span><%= format_tokens(@tokens_used) %>/<%= format_tokens(@tokens_max) %></span>
    <span style="color: #666;">│</span>
    <span>memory: <%= format_tokens(@memory_tokens) %>/<%= format_tokens(@memory_max) %></span>
    <span style="color: #666;">│</span>
    <span>$<%= format_cost(@cost) %></span>
    <span style="color: #666;">│</span>
    <span>turn <%= @turn %>/<%= @turn_limit %></span>
    <span style="color: #666;">│</span>
    <span style={"color: #{state_color(@state)};"}>
      ◉ <%= @state %>
    </span>
    """
  end

  defp render_orchestration_status(assigns) do
    ~H"""
    <span><%= @lead_count %> <%= pluralize("lead", @lead_count) %></span>
    <span style="color: #666;">│</span>
    <span><%= @completed %>/<%= @total %> complete</span>
    <span style="color: #666;">│</span>
    <span>$<%= format_cost(@cost) %>/$<%= format_cost(@cost_limit) %></span>
    <span style="color: #666;">│</span>
    <span><%= format_elapsed(@elapsed_seconds) %> elapsed</span>
    <span style="color: #666;">│</span>
    <span style={"color: #{state_color(@state)};"}>
      ◉ <%= @state %>
    </span>
    """
  end

  defp format_tokens(tokens) when tokens >= 1_000 do
    k = Float.round(tokens / 1000, 1)
    # Remove trailing .0
    if k == trunc(k) do
      "#{trunc(k)}k"
    else
      "#{k}k"
    end
  end

  defp format_tokens(tokens), do: "#{tokens}"

  defp format_cost(cost) when is_float(cost) do
    Float.round(cost, 2)
  end

  defp format_cost(cost), do: cost

  defp format_elapsed(seconds) when seconds < 60 do
    "#{seconds}s"
  end

  defp format_elapsed(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    "#{minutes}m"
  end

  defp format_elapsed(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h#{minutes}m"
  end

  defp state_color(:idle), do: "#6b7280"
  defp state_color(:waiting), do: "#eab308"
  defp state_color(:executing), do: "#10b981"
  defp state_color(:implementing), do: "#10b981"
  defp state_color(:complete), do: "#6b7280"
  defp state_color(:error), do: "#ef4444"
  defp state_color(_), do: "#a0a0a0"

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: "#{word}s"
end
