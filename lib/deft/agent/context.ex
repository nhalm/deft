defmodule Deft.Agent.Context do
  @moduledoc """
  Context assembly for agent turns.

  Assembles the message list that will be sent to the LLM provider on each turn.
  Per the harness spec section 4, context is assembled in this order:
  1. System prompt
  2. Observation injection (if OM is active)
  3. Conversation history
  4. Project context (DEFT.md/CLAUDE.md/AGENTS.md)

  This is a minimal initial implementation - system prompt, observations, and
  project context will be added in future work items.
  """

  @doc """
  Builds the context for an agent turn.

  For now, this is a minimal implementation that just returns the conversation
  history. Future work items will add system prompt, observations, and project
  context.

  ## Parameters

  - `messages` - The conversation history
  - `opts` - Options for context assembly (reserved for future use)

  ## Returns

  List of messages to send to the provider.
  """
  def build(messages, _opts \\ []) do
    # Minimal implementation: just return messages
    # Future work items will add:
    # - System prompt construction
    # - Observation injection
    # - Project context (DEFT.md/CLAUDE.md/AGENTS.md)
    messages
  end
end
