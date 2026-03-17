defmodule Deft.SlashCommand do
  @moduledoc """
  Handles slash command dispatch for user-initiated skill and command invocation.

  When a user types `/command-name args` in the TUI or CLI, this module:
  1. Parses the command name and arguments
  2. Looks up the command/skill in the Skills Registry
  3. Loads the definition
  4. Returns instructions for how to inject it into the conversation

  ## Command vs Skill Injection

  - Commands: markdown content is injected as a user message
  - Skills: definition is injected as a system instruction before the next agent turn

  Per spec section 1.3 and 2.4, this enables user-initiated slash command invocation
  separate from agent-initiated invocation via the use_skill tool.
  """

  alias Deft.Skills.Registry

  @type parse_result ::
          {:command, name :: String.t(), args :: String.t()}
          | {:not_slash, text :: String.t()}

  @type dispatch_result ::
          {:ok, :command, definition :: String.t()}
          | {:ok, :skill, definition :: String.t()}
          | {:error, :not_found, name :: String.t()}
          | {:error, :no_definition, name :: String.t()}

  @doc """
  Parses user input to detect slash commands.

  Returns:
  - `{:command, name, args}` if input starts with `/`
  - `{:not_slash, text}` if input does not start with `/`

  ## Examples

      iex> parse("/review")
      {:command, "review", ""}

      iex> parse("/commit --amend")
      {:command, "commit", "--amend"}

      iex> parse("regular text")
      {:not_slash, "regular text"}
  """
  @spec parse(String.t()) :: parse_result()
  def parse(input) do
    case String.trim(input) do
      "/" <> rest ->
        case String.split(rest, ~r/\s+/, parts: 2) do
          [name] -> {:command, name, ""}
          [name, args] -> {:command, name, args}
        end

      text ->
        {:not_slash, text}
    end
  end

  @doc """
  Dispatches a slash command by looking it up in the Registry and loading its definition.

  Returns:
  - `{:ok, :command, definition}` for commands (inject as user message)
  - `{:ok, :skill, definition}` for skills (inject as system instruction)
  - `{:error, :not_found, name}` if no command/skill with that name exists
  - `{:error, :no_definition, name}` if skill exists but has no definition (manifest-only)

  ## Examples

      iex> dispatch("review")
      {:ok, :skill, "You are performing a code review..."}

      iex> dispatch("commit")
      {:ok, :command, "Generate a commit message and commit"}

      iex> dispatch("nonexistent")
      {:error, :not_found, "nonexistent"}
  """
  @spec dispatch(String.t()) :: dispatch_result()
  def dispatch(name) do
    case Registry.lookup(name) do
      :not_found ->
        {:error, :not_found, name}

      entry ->
        case Registry.load_definition(name) do
          {:ok, definition} ->
            {:ok, entry.type, definition}

          {:error, :no_definition} ->
            {:error, :no_definition, name}

          {:error, _reason} ->
            {:error, :not_found, name}
        end
    end
  end
end
