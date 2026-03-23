defmodule DeftWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for Deft web UI.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.
  """
  attr(:flash, :map, required: true, doc: "the flash map")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :for={{kind, _msg} <- @flash}
        id={"flash-#{kind}"}
        phx-mounted={show("#flash-#{kind}")}
        phx-click={hide("#flash-#{kind}")}
        role="alert"
        class="flash"
      >
        <p><%= Phoenix.Flash.get(@flash, kind) %></p>
      </div>
    </div>
    """
  end

  defp show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  defp hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
