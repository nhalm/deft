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
  alias Deft.OM.State, as: OMState
  alias Deft.OM.Context, as: OMContext

  @doc """
  Builds the context for an agent turn.

  Assembles messages in order: system prompt, observations (if OM is active),
  conversation history (with observed messages trimmed), and project context files.

  ## Parameters

  - `messages` - The conversation history
  - `opts` - Options for context assembly:
    - `:config` - Agent configuration map (required for working_dir)
    - `:session_id` - Session ID for OM lookup (optional)

  ## Returns

  List of messages to send to the provider.
  """
  def build(messages, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    session_id = Keyword.get(opts, :session_id)

    # Get OM context if session_id is provided
    {observations, observed_ids, calibration_factor} =
      if session_id do
        get_om_context(session_id)
      else
        {"", [], 4.0}
      end

    # Inject observations and trim observed messages if OM is active
    processed_messages =
      if observations != "" and not Enum.empty?(observed_ids) do
        OMContext.inject(messages,
          observations: observations,
          observed_message_ids: observed_ids,
          calibration_factor: calibration_factor
        )
      else
        messages
      end

    [
      build_system_prompt(config),
      processed_messages,
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

  # Gets OM context from State process
  # Returns {observations, observed_ids, calibration_factor}
  defp get_om_context(session_id) do
    # Check if OM is enabled in config
    om_enabled = Application.get_env(:deft, :om_enabled, true)

    if om_enabled do
      # Check if OM.State process exists for this session
      case Registry.lookup(Deft.ProcessRegistry, {:om_state, session_id}) do
        [{_pid, _}] ->
          # Process exists, safe to call
          try do
            case OMState.get_context(session_id) do
              {observations, observed_ids} ->
                # TODO: Get calibration_factor from OM.State as well
                {observations, observed_ids, 4.0}

              _ ->
                {"", [], 4.0}
            end
          catch
            :exit, _ -> {"", [], 4.0}
          end

        [] ->
          # OM.State process doesn't exist - session not initialized with OM
          {"", [], 4.0}
      end
    else
      {"", [], 4.0}
    end
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
