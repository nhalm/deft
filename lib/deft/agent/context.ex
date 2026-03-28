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
    {observations, observed_ids, continuation_hint, calibration_factor} =
      if session_id do
        get_om_context(session_id, config)
      else
        {"", [], nil, 4.0}
      end

    # Inject observations and trim observed messages if OM is active
    processed_messages =
      if observations != "" and not Enum.empty?(observed_ids) do
        OMContext.inject(messages,
          observations: observations,
          observed_message_ids: observed_ids,
          calibration_factor: calibration_factor,
          continuation_hint: continuation_hint,
          message_token_threshold: config.om_message_token_threshold,
          buffer_tail_retention: config.om_buffer_tail_retention
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
  # Returns {observations, observed_ids, continuation_hint, calibration_factor}
  #
  # Per spec section 6.3, implements sync fallback:
  # - If pending_message_tokens >= 36,000 (1.2x observation threshold), force observe
  # - If observation_tokens >= 48,000 (1.2x reflection threshold), force reflect
  defp get_om_context(_session_id, %{om_enabled: false}), do: {"", [], nil, 4.0}

  defp get_om_context(session_id, config) do
    case Registry.lookup(Deft.ProcessRegistry, {:om_state, session_id}) do
      [{_pid, _}] -> fetch_om_state_with_sync(session_id, config)
      [] -> {"", [], nil, 4.0}
    end
  end

  # Fetches OM state and applies sync fallback if needed
  defp fetch_om_state_with_sync(session_id, config) do
    try do
      {_obs, _ids, _hint, _cal, pending_tokens, obs_tokens} = OMState.get_context(session_id)
      check_sync_fallback(session_id, config, pending_tokens, obs_tokens)
      extract_context_after_sync(session_id)
    catch
      :exit, _ -> {"", [], nil, 4.0}
    end
  end

  # Extracts context tuple after sync fallback
  defp extract_context_after_sync(session_id) do
    {observations, observed_ids, continuation_hint, calibration_factor, _, _} =
      OMState.get_context(session_id)

    {observations, observed_ids, continuation_hint, calibration_factor}
  end

  # Checks if sync fallback is needed and calls force_observe/force_reflect
  # Per spec section 6.3, this ensures observation/reflection happens even if async buffering fails
  defp check_sync_fallback(session_id, config, pending_message_tokens, observation_tokens) do
    # Hard threshold for observation: multiplier * message_token_threshold (per spec section 8)
    obs_hard_threshold =
      trunc(config.om_message_token_threshold * config.om_hard_threshold_multiplier)

    if pending_message_tokens >= obs_hard_threshold do
      case OMState.force_observe(session_id, 60_000) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Sync observe failed: #{inspect(reason)}")
          :ok
      end
    end

    # Hard threshold for reflection: multiplier * observation_token_threshold (per spec section 8)
    refl_hard_threshold =
      trunc(config.om_observation_token_threshold * config.om_hard_threshold_multiplier)

    if observation_tokens >= refl_hard_threshold do
      case OMState.force_reflect(session_id, 60_000) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Sync reflect failed: #{inspect(reason)}")
          :ok
      end
    end

    :ok
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
