defmodule Deft.Eval do
  @moduledoc """
  Domain types for eval system.

  Owns the core domain types used across eval modules:
  - `run_id()` - unique identifier for an eval run
  - `category()` - eval category identifier
  """

  @typedoc """
  Unique identifier for an eval run.

  Format: YYYY-MM-DD-<6-hex-chars>
  """
  @type run_id :: String.t()

  @typedoc """
  Eval category identifier.

  Categories group related eval tests (e.g., "observer_extraction", "reflector_compression").
  """
  @type category :: String.t()
end
