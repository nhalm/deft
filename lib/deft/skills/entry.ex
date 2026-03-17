defmodule Deft.Skills.Entry do
  @moduledoc """
  Represents a skill or command entry in the Skills Registry.

  Skills are structured capabilities defined in YAML files with a manifest
  (name, description, version) and a full definition (loaded on demand).
  Commands are simple markdown files whose contents are injected as prompts.

  Both exist at three levels with cascade: built-in (bundled with Deft),
  global (`~/.deft/`), and project (`.deft/`). Project overrides global
  overrides built-in when names collide.
  """

  @type skill_type :: :skill | :command
  @type level :: :builtin | :global | :project

  @type t :: %__MODULE__{
          name: String.t(),
          type: skill_type(),
          level: level(),
          description: String.t() | nil,
          path: String.t(),
          loaded: boolean()
        }

  @enforce_keys [:name, :type, :level, :path]

  defstruct [
    :name,
    :type,
    :level,
    :description,
    :path,
    loaded: false
  ]
end
