defmodule DeftWeb.Layouts do
  @moduledoc """
  Layout components for Deft web UI.
  """
  use DeftWeb, :html

  embed_templates("../layouts/*")
end
