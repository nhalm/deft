defmodule DeftWeb.Layouts do
  @moduledoc """
  Layout components for the Deft web UI.

  Provides root and app layouts using Phoenix.Component.
  """

  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes, endpoint: DeftWeb.Endpoint, router: DeftWeb.Router

  embed_templates("layouts/*")

  attr(:flash, :map, required: true)
  attr(:kind, :atom, values: [:info, :error], doc: "the flash kind")

  def flash_group(assigns) do
    ~H"""
    <div :for={{kind, message} <- @flash} class={"flash flash-#{kind}"}>
      <%= message %>
    </div>
    """
  end
end
