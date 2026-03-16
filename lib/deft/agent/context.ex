defmodule Deft.Agent.Context do
  @moduledoc """
  Context assembly for agent turns.

  Assembles the message list that will be sent to the LLM provider on each turn.
  Per the harness spec section 4, context is assembled in this order:
  1. System prompt
  2. Observation injection (if OM is active)
  3. Conversation history
  4. Project context (DEFT.md/CLAUDE.md/AGENTS.md)
  """

  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Agent.SystemPrompt

  @doc """
  Builds the context for an agent turn.

  Assembles messages in order: system prompt, observations (empty for now),
  conversation history, and project context files.

  ## Parameters

  - `messages` - The conversation history
  - `opts` - Options for context assembly:
    - `:config` - Agent configuration map (required for working_dir)

  ## Returns

  List of messages to send to the provider.
  """
  def build(messages, opts \\ []) do
    config = Keyword.get(opts, :config, %{})

    [
      build_system_prompt(config),
      build_observation_injection(),
      messages,
      build_project_context(config)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # Builds the system prompt message using SystemPrompt.build/1
  defp build_system_prompt(config) do
    prompt_text = SystemPrompt.build(config)

    %Message{
      id: "sys_prompt",
      role: :system,
      content: [%Text{text: prompt_text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Builds the observation injection message
  # Returns nil for now since OM is not yet implemented.
  # When OM is active, this will return a system message with observations.
  defp build_observation_injection do
    nil
  end

  # Builds the project context message by reading DEFT.md, CLAUDE.md, or AGENTS.md
  defp build_project_context(config) do
    working_dir = Map.get(config, :working_dir, File.cwd!())

    case read_project_context_file(working_dir) do
      {:ok, content} ->
        %Message{
          id: "project_context",
          role: :system,
          content: [%Text{text: content}],
          timestamp: DateTime.utc_now()
        }

      :error ->
        nil
    end
  end

  # Reads project context from DEFT.md, CLAUDE.md, or AGENTS.md
  # Priority: DEFT.md > CLAUDE.md > AGENTS.md
  defp read_project_context_file(working_dir) do
    candidates = ["DEFT.md", "CLAUDE.md", "AGENTS.md"]

    Enum.reduce_while(candidates, :error, fn filename, _acc ->
      path = Path.join(working_dir, filename)

      case File.read(path) do
        {:ok, content} ->
          # If CLAUDE.md contains just a reference to another file, follow it
          content = resolve_reference(content, working_dir)
          {:halt, {:ok, content}}

        {:error, _} ->
          {:cont, :error}
      end
    end)
  end

  # Resolves file references in CLAUDE.md
  # If content is just a filename (like "AGENTS.md"), read that file instead
  defp resolve_reference(content, working_dir) do
    trimmed = String.trim(content)

    if String.match?(trimmed, ~r/^[A-Z_]+\.md$/i) do
      referenced_path = Path.join(working_dir, trimmed)

      case File.read(referenced_path) do
        {:ok, referenced_content} -> referenced_content
        {:error, _} -> content
      end
    else
      content
    end
  end
end
