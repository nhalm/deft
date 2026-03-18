defmodule Deft.OM.State do
  @moduledoc """
  GenServer that holds state for the Observational Memory system.

  This process owns all OM state and coordinates Observer/Reflector Tasks:
  - Active observations that are injected into every turn
  - Buffered chunks from pre-computed observation cycles
  - Metadata about what messages have been observed
  - Flags for in-flight observation/reflection cycles
  - Token counts and calibration data

  The State process spawns Observer/Reflector Tasks via the TaskSupervisor
  and handles their results asynchronously via handle_info.
  """

  use GenServer
  require Logger

  alias Deft.{Config, Message}
  alias Deft.OM.{BufferedChunk, Observer, Reflector, Supervisor, Tokens}
  alias Deft.OM.Observer.Parse
  alias Deft.Session.Entry.Observation, as: ObservationEntry

  # Default thresholds from spec section 8
  @default_message_threshold 30_000
  @default_observation_threshold 40_000
  @default_buffer_interval 0.2

  @type t :: %__MODULE__{
          session_id: String.t(),
          config: Config.t(),
          messages: [Message.t()],
          active_observations: String.t(),
          observation_tokens: integer(),
          buffered_chunks: [BufferedChunk.t()],
          buffered_reflection: String.t() | nil,
          buffered_reflection_epoch: integer() | nil,
          last_observed_at: DateTime.t() | nil,
          observed_message_ids: [String.t()],
          pending_message_tokens: integer(),
          generation_count: integer(),
          is_observing: boolean(),
          is_reflecting: boolean(),
          needs_rebuffer: boolean(),
          activation_epoch: integer(),
          snapshot_dirty: boolean(),
          calibration_factor: float(),
          sync_from: GenServer.from() | nil,
          observer_ref: reference() | nil,
          reflector_ref: reference() | nil,
          is_buffering_reflection: boolean(),
          last_buffer_threshold: integer(),
          consecutive_failures: integer(),
          circuit_open: boolean(),
          circuit_opened_at: DateTime.t() | nil,
          continuation_hint: String.t() | nil
        }

  @enforce_keys [:session_id, :config]
  defstruct [
    :session_id,
    :config,
    :observer_ref,
    :reflector_ref,
    messages: [],
    active_observations: "",
    observation_tokens: 0,
    buffered_chunks: [],
    buffered_reflection: nil,
    buffered_reflection_epoch: nil,
    last_observed_at: nil,
    observed_message_ids: [],
    pending_message_tokens: 0,
    generation_count: 0,
    is_observing: false,
    is_reflecting: false,
    is_buffering_reflection: false,
    needs_rebuffer: false,
    activation_epoch: 0,
    snapshot_dirty: false,
    calibration_factor: 4.0,
    sync_from: nil,
    last_buffer_threshold: 0,
    consecutive_failures: 0,
    circuit_open: false,
    circuit_opened_at: nil,
    continuation_hint: nil
  ]

  ## Client API

  @doc """
  Starts the OM State GenServer for the given session.

  ## Options

  - `:session_id` — Required. Session identifier.
  - `:config` — Required. Configuration struct.
  - `:messages` — Optional. Messages for computing pending tokens on resume.
  - `:snapshot` — Optional. Observation entry to restore from.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    messages = Keyword.get(opts, :messages, [])
    snapshot = Keyword.get(opts, :snapshot)

    GenServer.start_link(
      __MODULE__,
      {session_id, config, messages, snapshot},
      name: via_tuple(session_id)
    )
  end

  @doc """
  Returns the current observation context for injection into the Agent's context.

  Returns `{observations_text, observed_message_ids}`.
  """
  @spec get_context(String.t()) :: {String.t(), [String.t()], String.t() | nil}
  def get_context(session_id) do
    GenServer.call(via_tuple(session_id), :get_context)
  end

  @doc """
  Notifies State that new messages have been added.

  Accepts a list of Deft.Message structs.
  Updates pending_message_tokens and spawns Observer Tasks when buffer intervals are crossed.
  """
  @spec messages_added(String.t(), [Message.t()]) :: :ok
  def messages_added(session_id, messages) do
    GenServer.cast(via_tuple(session_id), {:messages_added, messages})
  end

  @doc """
  Loads the latest OM snapshot from disk for the given session.

  Returns `{:ok, observation_entry}` if a snapshot exists, or `{:ok, nil}` if no snapshot found.
  Returns `{:error, reason}` if the file exists but cannot be read or parsed.

  Per spec section 9.3, this is called during session resume to restore OM state.
  """
  @spec load_latest_snapshot(String.t()) :: {:ok, ObservationEntry.t() | nil} | {:error, term()}
  def load_latest_snapshot(session_id) do
    path = om_snapshot_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        # Parse all lines and take the last one (most recent)
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_snapshot_line/1)
          |> Enum.reject(&is_nil/1)

        latest = List.last(entries)
        {:ok, latest}

      {:error, :enoent} ->
        # File doesn't exist yet (new session) - this is not an error
        {:ok, nil}

      {:error, reason} = error ->
        Logger.warning("Failed to load OM snapshot for session #{session_id}: #{inspect(reason)}")

        error
    end
  end

  ## Server Callbacks

  @impl true
  def init({session_id, config, messages, snapshot}) do
    Logger.debug("Starting OM State for session #{session_id}")

    # Schedule periodic snapshot timer (every 60 seconds)
    schedule_snapshot_timer()

    # Create initial state
    initial_state = %__MODULE__{session_id: session_id, config: config}

    # If we have a snapshot, restore from it
    state =
      case snapshot do
        nil ->
          initial_state

        %ObservationEntry{} = snap ->
          restore_from_snapshot(initial_state, snap, messages)
      end

    {:ok, state}
  end

  # Restore state from a snapshot (spec section 9.3)
  defp restore_from_snapshot(state, snapshot, messages) do
    Logger.info(
      "Restoring OM state for session #{state.session_id} from snapshot: #{snapshot.observation_tokens} tokens, #{length(snapshot.observed_message_ids)} messages observed"
    )

    # Restore all persisted fields from snapshot (spec section 9.2)
    restored_state = %{
      state
      | active_observations: snapshot.active_observations,
        observation_tokens: snapshot.observation_tokens,
        observed_message_ids: snapshot.observed_message_ids,
        generation_count: snapshot.generation_count,
        last_observed_at: snapshot.last_observed_at,
        activation_epoch: snapshot.activation_epoch,
        calibration_factor: snapshot.calibration_factor,
        messages: messages
    }

    # Recompute pending_message_tokens from messages not in observed_message_ids
    # Per spec section 9.3: use message IDs as authoritative boundary
    unobserved_messages =
      messages
      |> Enum.reject(fn msg -> msg.id in snapshot.observed_message_ids end)

    pending_tokens =
      unobserved_messages
      |> Enum.map(fn msg ->
        content_text = extract_message_text(msg)
        Tokens.estimate(content_text, snapshot.calibration_factor)
      end)
      |> Enum.sum()

    restored_state = %{restored_state | pending_message_tokens: pending_tokens}

    Logger.debug(
      "OM state restored: #{restored_state.observation_tokens} observation tokens, #{pending_tokens} pending tokens from #{length(unobserved_messages)} unobserved messages"
    )

    # Check if thresholds are already exceeded and trigger observation/reflection if needed
    # Per spec section 9.3: "If thresholds are already exceeded, trigger observation/reflection immediately"
    restored_state
    |> check_and_spawn_observer()
    |> check_and_spawn_reflector()
  end

  @impl true
  def terminate(_reason, state) do
    # Write final snapshot on shutdown if state has changed (spec section 9.1)
    if state.snapshot_dirty do
      case write_snapshot(state) do
        :ok ->
          Logger.debug("Final OM snapshot written for session #{state.session_id} on shutdown")

        {:error, reason} ->
          Logger.warning(
            "Failed to write final OM snapshot for session #{state.session_id} on shutdown: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, {state.active_observations, state.observed_message_ids, state.continuation_hint},
     state}
  end

  @impl true
  def handle_call(:force_observe, from, state) do
    Logger.info(
      "Force observe called for session #{state.session_id} (sync fallback) - pending: #{state.pending_message_tokens} tokens"
    )

    # Get unobserved messages
    unobserved_messages =
      state.messages
      |> Enum.reject(fn msg -> msg.id in state.observed_message_ids end)

    # If no unobserved messages, return immediately
    if Enum.empty?(unobserved_messages) do
      {:reply, {:ok, :no_messages}, state}
    else
      # Emit sync fallback event
      broadcast_event(state.session_id, {:om, :sync_fallback, %{type: :observation}})
      # Emit observation_started event (LLM call begins immediately)
      broadcast_event(state.session_id, {:om, :observation_started})

      task_supervisor = Supervisor.task_supervisor_name(state.session_id)

      # Spawn Observer Task with 1 retry max (sync path)
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          run_observer_with_retry(
            state.config,
            unobserved_messages,
            state.active_observations,
            state.calibration_factor,
            1
          )
        end)

      # Stash the caller's from, spawn Task, return {:noreply, state}
      # When Task completes, handle_info will reply via GenServer.reply/2
      state = %{
        state
        | sync_from: from,
          is_observing: true,
          observer_ref: task.ref
      }

      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:force_reflect, from, state) do
    Logger.info(
      "Force reflect called for session #{state.session_id} (sync fallback) - observation_tokens: #{state.observation_tokens}"
    )

    # If observation_tokens is below threshold, return immediately
    if state.observation_tokens < @default_observation_threshold do
      {:reply, {:ok, :below_threshold}, state}
    else
      # Emit sync fallback event
      broadcast_event(state.session_id, {:om, :sync_fallback, %{type: :reflection}})
      # Emit reflection_started event (LLM call begins immediately)
      broadcast_event(state.session_id, {:om, :reflection_started, %{level: 0}})

      task_supervisor = Supervisor.task_supervisor_name(state.session_id)

      # Target size is 50% of reflection threshold (per spec section 4.3)
      target_size = div(@default_observation_threshold, 2)

      # Spawn Reflector Task with 1 retry max (sync path)
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          run_reflector_with_retry(
            state.config,
            state.active_observations,
            target_size,
            state.calibration_factor,
            1
          )
        end)

      # Stash the caller's from, spawn Task, return {:noreply, state}
      # When Task completes, handle_info will reply via GenServer.reply/2
      state = %{
        state
        | sync_from: from,
          is_reflecting: true,
          reflector_ref: task.ref
      }

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:messages_added, new_messages}, state) do
    # Calculate new pending tokens from the new messages
    new_tokens =
      new_messages
      |> Enum.map(fn msg ->
        # Estimate tokens from message content
        content_text = extract_message_text(msg)
        Tokens.estimate(content_text, state.calibration_factor)
      end)
      |> Enum.sum()

    new_pending = state.pending_message_tokens + new_tokens

    # Append new messages to the message list
    all_messages = state.messages ++ new_messages

    # Check if we crossed a buffer interval threshold
    state =
      %{state | pending_message_tokens: new_pending, messages: all_messages}
      |> check_and_spawn_observer()

    {:noreply, state}
  end

  defp extract_message_text(message) do
    alias Deft.Message.{Text, ToolUse, ToolResult, Thinking, Image}

    message.content
    |> Enum.map(fn
      %Text{text: text} -> text
      %ToolUse{name: name, args: args} -> "#{name}(#{inspect(args)})"
      %ToolResult{content: content} -> content
      %Thinking{text: text} -> text
      %Image{} -> "[image]"
    end)
    |> Enum.join(" ")
  end

  @impl true
  def handle_info({ref, result}, %{observer_ref: ref} = state) when ref != nil do
    # Observer Task completed successfully
    Logger.debug("Observer Task completed for session #{state.session_id}")

    # Demonitor the task
    Process.demonitor(ref, [:flush])

    # Check if observations are empty (indicates failure)
    is_success = result.observations != ""

    # Emit observation_complete event if successful
    if is_success do
      tokens_produced = Tokens.estimate(result.observations, state.calibration_factor)

      broadcast_event(state.session_id, {
        :om,
        :observation_complete,
        %{tokens_observed: result.message_tokens, tokens_produced: tokens_produced}
      })
    end

    # Record success/failure for circuit breaker
    state =
      if is_success do
        record_cycle_success(state)
      else
        record_cycle_failure(state, :observation, :empty_observations)
      end

    # Check if this is a sync fallback call
    if state.sync_from do
      handle_sync_observer_completion(state, result, is_success)
    else
      # Normal async buffering path - only store the chunk if successful
      state =
        if is_success do
          # Emit buffering_complete event for async path
          broadcast_event(state.session_id, {:om, :buffering_complete, %{type: :observation}})

          chunk = %BufferedChunk{
            observations: result.observations,
            token_count: Tokens.estimate(result.observations, state.calibration_factor),
            message_ids: result.message_ids,
            message_tokens: result.message_tokens,
            epoch: state.activation_epoch,
            continuation_hint: result.continuation_hint
          }

          %{
            state
            | buffered_chunks: state.buffered_chunks ++ [chunk],
              is_observing: false,
              observer_ref: nil
          }
        else
          %{
            state
            | is_observing: false,
              observer_ref: nil
          }
        end

      # Check if we need to re-observe (coalescing)
      state =
        if state.needs_rebuffer do
          %{state | needs_rebuffer: false}
          |> check_and_spawn_observer()
        else
          state
        end

      # After Observer completes, check if reflection should be triggered
      # (now that is_observing is false)
      state = check_and_spawn_reflector(state)

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{observer_ref: ref} = state)
      when ref != nil do
    # Observer Task crashed or failed
    Logger.warning("Observer Task failed for session #{state.session_id}: #{inspect(reason)}")

    # Record failure for circuit breaker
    state = record_cycle_failure(state, :observation, reason)

    # Check if this is a sync fallback call
    if state.sync_from do
      # Reply to the stashed caller with an error
      GenServer.reply(state.sync_from, {:error, reason})

      # Clear sync_from and flags
      state = %{
        state
        | sync_from: nil,
          is_observing: false,
          observer_ref: nil
      }

      {:noreply, state}
    else
      # Normal async path
      state = %{
        state
        | is_observing: false,
          observer_ref: nil
      }

      # Check if we need to re-observe (coalescing)
      state =
        if state.needs_rebuffer do
          %{state | needs_rebuffer: false}
          |> check_and_spawn_observer()
        else
          state
        end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{reflector_ref: ref} = state) when ref != nil do
    # Reflector Task completed successfully
    Logger.info(
      "Reflector Task completed for session #{state.session_id}: #{result.before_tokens} -> #{result.after_tokens} tokens (level #{result.compression_level}, #{result.llm_calls} calls)"
    )

    # Demonitor the task
    Process.demonitor(ref, [:flush])

    # Check if result indicates success
    is_success = result.compressed_observations != ""

    # Record success/failure for circuit breaker
    state =
      if is_success do
        record_cycle_success(state)
      else
        record_cycle_failure(state, :reflection, :empty_compressed_observations)
      end

    # Check if this is a sync fallback call
    if state.sync_from do
      handle_sync_reflector_completion(state, result, is_success)
    else
      # Check if this was a buffered reflection or immediate reflection
      state =
        if state.is_buffering_reflection do
          # This was a buffered reflection - store it for later activation
          Logger.debug(
            "Storing buffered reflection for session #{state.session_id} (epoch #{result.epoch})"
          )

          # Emit buffering_complete event
          broadcast_event(state.session_id, {:om, :buffering_complete, %{type: :reflection}})

          state = %{
            state
            | buffered_reflection: result.compressed_observations,
              buffered_reflection_epoch: result.epoch,
              is_buffering_reflection: false,
              reflector_ref: nil
          }

          # After buffering completes, check if we should activate immediately
          # (in case we already crossed the full threshold while buffering)
          check_and_spawn_reflector(state)
        else
          # This was an immediate reflection - apply it now
          # Emit reflection_complete event
          broadcast_event(state.session_id, {
            :om,
            :reflection_complete,
            %{before_tokens: result.before_tokens, after_tokens: result.after_tokens}
          })

          # Replace active_observations with compressed result
          # Increment generation_count and activation_epoch
          state = %{
            state
            | active_observations: result.compressed_observations,
              observation_tokens: result.after_tokens,
              generation_count: state.generation_count + 1,
              activation_epoch: state.activation_epoch + 1,
              is_reflecting: false,
              reflector_ref: nil,
              snapshot_dirty: true
          }

          # Check if hard cap truncation is needed (spec section 4.6)
          state = maybe_apply_hard_cap(state)

          # Write snapshot after reflection activation (spec section 9.1)
          state =
            case write_snapshot(state) do
              :ok ->
                %{state | snapshot_dirty: false}

              {:error, _reason} ->
                # Log already happened in write_snapshot, continue with dirty flag set
                state
            end

          # After Reflector completes, check if there are buffered chunks to activate
          # (now that is_reflecting is false)
          if not Enum.empty?(state.buffered_chunks) and
               state.pending_message_tokens >= @default_message_threshold do
            activate_buffered_chunks(state)
          else
            state
          end
        end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reflector_ref: ref} = state)
      when ref != nil do
    # Reflector Task crashed or failed
    Logger.warning("Reflector Task failed for session #{state.session_id}: #{inspect(reason)}")

    # Record failure for circuit breaker
    state = record_cycle_failure(state, :reflection, reason)

    # Check if this is a sync fallback call
    if state.sync_from do
      # Reply to the stashed caller with an error
      GenServer.reply(state.sync_from, {:error, reason})

      # Clear sync_from and flags
      state = %{
        state
        | sync_from: nil,
          is_reflecting: false,
          reflector_ref: nil
      }

      {:noreply, state}
    else
      # Normal async path
      state = %{
        state
        | is_reflecting: false,
          is_buffering_reflection: false,
          reflector_ref: nil
      }

      # Check if hard cap truncation is needed after failure (spec section 4.6)
      state = maybe_apply_hard_cap(state)

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Ignore stale task results
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    # Ignore stale task crashes
    {:noreply, state}
  end

  @impl true
  def handle_info(:snapshot_timer, state) do
    # Periodic snapshot timer (every 60 seconds)
    # Only write if state has changed (snapshot_dirty flag)
    state =
      if state.snapshot_dirty do
        case write_snapshot(state) do
          :ok ->
            %{state | snapshot_dirty: false}

          {:error, reason} ->
            Logger.warning(
              "Failed to write periodic snapshot for session #{state.session_id}: #{inspect(reason)}"
            )

            state
        end
      else
        state
      end

    # Reschedule next timer
    schedule_snapshot_timer()

    {:noreply, state}
  end

  ## Private Functions

  # Handle sync observer completion (spec section 6.3)
  # Per spec: merge observations into active_observations, update observed_message_ids,
  # and decrement pending_message_tokens BEFORE replying
  defp handle_sync_observer_completion(state, result, is_success) do
    # Merge observations if successful
    state =
      if is_success do
        # Section-aware merge observations into active_observations
        merged_observations =
          Parse.merge_observations(state.active_observations, result.observations)

        # Update observed_message_ids
        new_observed_message_ids = state.observed_message_ids ++ result.message_ids

        # Calculate new observation tokens
        new_observation_tokens = Tokens.estimate(merged_observations, state.calibration_factor)

        # Decrement pending_message_tokens by the observed message tokens
        new_pending = max(0, state.pending_message_tokens - result.message_tokens)

        # Update continuation hint if present
        new_continuation_hint =
          if is_binary(result.continuation_hint) and result.continuation_hint != "" do
            result.continuation_hint
          else
            state.continuation_hint
          end

        %{
          state
          | active_observations: merged_observations,
            observation_tokens: new_observation_tokens,
            observed_message_ids: new_observed_message_ids,
            pending_message_tokens: new_pending,
            activation_epoch: state.activation_epoch + 1,
            snapshot_dirty: true,
            last_observed_at: DateTime.utc_now(),
            continuation_hint: new_continuation_hint
        }
      else
        # Keep state unchanged on failure
        state
      end

    # Reply to the stashed caller with the result
    GenServer.reply(state.sync_from, {:ok, result})

    # Clear sync_from and flags
    state = %{
      state
      | sync_from: nil,
        is_observing: false,
        observer_ref: nil
    }

    # Write snapshot after sync observation if state was updated (spec section 9.1)
    state =
      if is_success do
        case write_snapshot(state) do
          :ok ->
            state = %{state | snapshot_dirty: false}
            # Check if reflection should be triggered
            check_and_spawn_reflector(state)

          {:error, _reason} ->
            # Log already happened in write_snapshot, continue with dirty flag set
            check_and_spawn_reflector(state)
        end
      else
        state
      end

    {:noreply, state}
  end

  # Handle sync reflector completion (spec section 6.3)
  # Per spec: replace active_observations with compressed result BEFORE replying
  defp handle_sync_reflector_completion(state, result, is_success) do
    # Apply reflection if successful
    state =
      if is_success do
        # Emit reflection_complete event
        broadcast_event(state.session_id, {
          :om,
          :reflection_complete,
          %{before_tokens: result.before_tokens, after_tokens: result.after_tokens}
        })

        # Replace active_observations with compressed result
        # Increment generation_count and activation_epoch
        state = %{
          state
          | active_observations: result.compressed_observations,
            observation_tokens: result.after_tokens,
            generation_count: state.generation_count + 1,
            activation_epoch: state.activation_epoch + 1,
            snapshot_dirty: true
        }

        # Check if hard cap truncation is needed (spec section 4.6)
        maybe_apply_hard_cap(state)
      else
        # Keep state unchanged on failure
        state
      end

    # Reply to the stashed caller with the result
    GenServer.reply(state.sync_from, {:ok, result})

    # Clear sync_from and flags
    state = %{
      state
      | sync_from: nil,
        is_reflecting: false,
        reflector_ref: nil
    }

    # Write snapshot after sync reflection if state was updated (spec section 9.1)
    state =
      if is_success do
        case write_snapshot(state) do
          :ok ->
            %{state | snapshot_dirty: false}

          {:error, _reason} ->
            # Log already happened in write_snapshot, continue with dirty flag set
            state
        end
      else
        state
      end

    {:noreply, state}
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}}
  end

  defp run_observer_with_retry(
         config,
         messages,
         existing_observations,
         calibration_factor,
         max_retries
       ) do
    run_observer_with_retry_loop(
      config,
      messages,
      existing_observations,
      calibration_factor,
      max_retries,
      0
    )
  end

  defp run_observer_with_retry_loop(
         config,
         messages,
         existing_observations,
         calibration_factor,
         max_retries,
         attempt
       ) do
    case Observer.run(config, messages, existing_observations, calibration_factor) do
      %{observations: ""} when attempt < max_retries ->
        # Empty observations means failure - retry with exponential backoff
        backoff_ms = trunc(:math.pow(2, attempt) * 1000)
        Logger.warning("Observer attempt #{attempt + 1} failed, retrying after #{backoff_ms}ms")
        Process.sleep(backoff_ms)

        run_observer_with_retry_loop(
          config,
          messages,
          existing_observations,
          calibration_factor,
          max_retries,
          attempt + 1
        )

      result ->
        # Success or max retries reached
        result
    end
  end

  defp run_reflector_with_retry(
         config,
         observations,
         target_size,
         calibration_factor,
         max_retries
       ) do
    run_reflector_with_retry_loop(
      config,
      observations,
      target_size,
      calibration_factor,
      max_retries,
      0
    )
  end

  defp run_reflector_with_retry_loop(
         config,
         observations,
         target_size,
         calibration_factor,
         max_retries,
         attempt
       ) do
    case Reflector.run(config, observations, target_size, calibration_factor) do
      %{compressed_observations: ""} when attempt < max_retries ->
        # Empty compressed observations means failure - retry with exponential backoff
        backoff_ms = trunc(:math.pow(2, attempt) * 1000)
        Logger.warning("Reflector attempt #{attempt + 1} failed, retrying after #{backoff_ms}ms")
        Process.sleep(backoff_ms)

        run_reflector_with_retry_loop(
          config,
          observations,
          target_size,
          calibration_factor,
          max_retries,
          attempt + 1
        )

      result ->
        # Success or max retries reached
        result
    end
  end

  defp check_and_spawn_observer(state) do
    buffer_size = trunc(@default_message_threshold * @default_buffer_interval)
    current_threshold = div(state.pending_message_tokens, buffer_size) * buffer_size

    # First, check if we should activate buffered chunks
    # Serialization: do not activate if is_reflecting is true
    state = maybe_activate_buffered_chunks(state)

    # Then check if we should spawn observer for buffering
    maybe_spawn_observer_for_buffering(state, buffer_size, current_threshold)
  end

  defp maybe_activate_buffered_chunks(state) do
    if state.pending_message_tokens >= @default_message_threshold and
         not Enum.empty?(state.buffered_chunks) and
         not state.is_reflecting do
      activate_buffered_chunks(state)
    else
      state
    end
  end

  defp maybe_spawn_observer_for_buffering(state, buffer_size, current_threshold) do
    cond do
      # Already observing - set rebuffer flag if we crossed another threshold
      state.is_observing and current_threshold > state.last_buffer_threshold ->
        %{state | needs_rebuffer: true}

      # Not observing and crossed a new threshold - spawn Observer
      not state.is_observing and current_threshold > state.last_buffer_threshold and
          state.pending_message_tokens >= buffer_size ->
        spawn_observer_task(state, current_threshold)

      # No action needed
      true ->
        state
    end
  end

  defp spawn_observer_task(state, threshold) do
    # Check circuit breaker before spawning
    if not can_attempt_cycle?(state) do
      Logger.debug(
        "Skipping Observer spawn for session #{state.session_id} - circuit breaker is open"
      )

      state
    else
      # Reset circuit if cooldown has expired
      state = if state.circuit_open, do: reset_circuit(state), else: state

      Logger.debug(
        "Spawning Observer Task for session #{state.session_id} at #{state.pending_message_tokens} tokens"
      )

      # Emit buffering_started event for async buffering
      broadcast_event(state.session_id, {:om, :buffering_started, %{type: :observation}})
      # Emit observation_started event (LLM call begins immediately)
      broadcast_event(state.session_id, {:om, :observation_started})

      # Get unobserved messages
      unobserved_messages =
        state.messages
        |> Enum.reject(fn msg -> msg.id in state.observed_message_ids end)

      task_supervisor = Supervisor.task_supervisor_name(state.session_id)

      # Spawn Observer Task with actual Observer.run/4 call
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          Observer.run(
            state.config,
            unobserved_messages,
            state.active_observations,
            state.calibration_factor
          )
        end)

      %{
        state
        | is_observing: true,
          observer_ref: task.ref,
          last_buffer_threshold: threshold
      }
    end
  end

  defp activate_buffered_chunks(state) do
    Logger.info(
      "Activating #{length(state.buffered_chunks)} buffered chunks for session #{state.session_id}"
    )

    # Emit activation event
    broadcast_event(state.session_id, {:om, :activation, %{type: :observation}})

    # Filter out stale chunks (epoch < current activation_epoch) per spec section 6.1
    # Stale chunks were computed against pre-reflection state
    current_chunks =
      Enum.filter(state.buffered_chunks, fn chunk ->
        chunk.epoch >= state.activation_epoch
      end)

    # Log if any chunks were discarded
    discarded_count = length(state.buffered_chunks) - length(current_chunks)

    if discarded_count > 0 do
      Logger.debug(
        "Discarded #{discarded_count} stale chunks (epoch < #{state.activation_epoch}) for session #{state.session_id}"
      )
    end

    # Section-aware merge all current (non-stale) chunks into active_observations
    merged_observations =
      Enum.reduce(current_chunks, state.active_observations, fn chunk, acc ->
        Parse.merge_observations(acc, chunk.observations)
      end)

    # Collect all message_ids from current (non-stale) chunks
    all_message_ids =
      Enum.flat_map(current_chunks, fn chunk -> chunk.message_ids end)

    # Add chunk message_ids to observed_message_ids
    new_observed_message_ids = state.observed_message_ids ++ all_message_ids

    # Calculate tokens for merged observations
    new_observation_tokens = Tokens.estimate(merged_observations, state.calibration_factor)

    # Calculate how many tokens were observed (to subtract from pending)
    observed_tokens =
      Enum.reduce(current_chunks, 0, fn chunk, acc -> acc + chunk.message_tokens end)

    # Subtract observed tokens from pending
    new_pending = max(0, state.pending_message_tokens - observed_tokens)

    # Get the most recent continuation hint (from the last chunk)
    new_continuation_hint =
      case List.last(current_chunks) do
        %BufferedChunk{continuation_hint: hint} when not is_nil(hint) -> hint
        _ -> state.continuation_hint
      end

    state = %{
      state
      | active_observations: merged_observations,
        observation_tokens: new_observation_tokens,
        buffered_chunks: [],
        observed_message_ids: new_observed_message_ids,
        pending_message_tokens: new_pending,
        activation_epoch: state.activation_epoch + 1,
        snapshot_dirty: true,
        last_observed_at: DateTime.utc_now(),
        continuation_hint: new_continuation_hint
    }

    # Write snapshot after observation activation (spec section 9.1)
    case write_snapshot(state) do
      :ok ->
        state = %{state | snapshot_dirty: false}
        # Check if we should trigger reflection
        check_and_spawn_reflector(state)

      {:error, _reason} ->
        # Log already happened in write_snapshot, continue with dirty flag set
        check_and_spawn_reflector(state)
    end
  end

  defp check_and_spawn_reflector(state) do
    # Per spec section 6.2, buffering triggers at 50% of threshold (20,000 tokens)
    buffer_threshold = div(@default_observation_threshold, 2)

    cond do
      # Full threshold reached - activate buffered reflection or spawn immediate reflection
      should_activate_reflection?(state) ->
        activate_or_spawn_reflection(state)

      # Buffer threshold reached - spawn buffered Reflector Task
      should_buffer_reflection?(state, buffer_threshold) ->
        spawn_buffered_reflector_task(state)

      # No action needed
      true ->
        state
    end
  end

  defp should_activate_reflection?(state) do
    state.observation_tokens >= @default_observation_threshold and
      not state.is_reflecting and
      not state.is_observing
  end

  defp should_buffer_reflection?(state, buffer_threshold) do
    state.observation_tokens >= buffer_threshold and
      not state.is_reflecting and
      not state.is_buffering_reflection and
      not state.is_observing and
      is_nil(state.buffered_reflection)
  end

  # Per spec section 6.2: check if buffered reflection is current and use it,
  # or discard and re-trigger if stale
  defp activate_or_spawn_reflection(state) do
    if not is_nil(state.buffered_reflection) and
         not is_nil(state.buffered_reflection_epoch) do
      # We have a buffered reflection - check if it's current
      if state.buffered_reflection_epoch == state.activation_epoch do
        # Buffered reflection is current - activate it instantly
        Logger.info(
          "Activating buffered reflection for session #{state.session_id} (epoch #{state.activation_epoch})"
        )

        activate_buffered_reflection(state)
      else
        # Buffered reflection is stale - discard and re-trigger
        Logger.debug(
          "Discarding stale buffered reflection for session #{state.session_id} (epoch #{state.buffered_reflection_epoch} < #{state.activation_epoch})"
        )

        state = %{state | buffered_reflection: nil, buffered_reflection_epoch: nil}
        spawn_reflector_task(state)
      end
    else
      # No buffered reflection - spawn immediate reflection
      spawn_reflector_task(state)
    end
  end

  # Activate the buffered reflection (instant, no LLM call needed)
  defp activate_buffered_reflection(state) do
    # Emit activation event
    broadcast_event(state.session_id, {:om, :activation, %{type: :reflection}})

    before_tokens = state.observation_tokens
    after_tokens = Tokens.estimate(state.buffered_reflection, state.calibration_factor)

    # Emit reflection_complete event
    broadcast_event(state.session_id, {
      :om,
      :reflection_complete,
      %{before_tokens: before_tokens, after_tokens: after_tokens}
    })

    Logger.info(
      "Activated buffered reflection for session #{state.session_id}: #{before_tokens} -> #{after_tokens} tokens"
    )

    # Replace active_observations with buffered reflection
    # Increment generation_count and activation_epoch
    state = %{
      state
      | active_observations: state.buffered_reflection,
        observation_tokens: after_tokens,
        generation_count: state.generation_count + 1,
        activation_epoch: state.activation_epoch + 1,
        buffered_reflection: nil,
        buffered_reflection_epoch: nil,
        snapshot_dirty: true
    }

    # Check if hard cap truncation is needed
    state = maybe_apply_hard_cap(state)

    # Write snapshot after reflection activation (spec section 9.1)
    case write_snapshot(state) do
      :ok ->
        %{state | snapshot_dirty: false}

      {:error, _reason} ->
        # Log already happened in write_snapshot, continue with dirty flag set
        state
    end
  end

  # Spawn a buffered Reflector Task (per spec section 6.2)
  # Task carries the current activation_epoch
  defp spawn_buffered_reflector_task(state) do
    # Check circuit breaker before spawning
    if not can_attempt_cycle?(state) do
      Logger.debug(
        "Skipping buffered Reflector spawn for session #{state.session_id} - circuit breaker is open"
      )

      state
    else
      # Reset circuit if cooldown has expired
      state = if state.circuit_open, do: reset_circuit(state), else: state

      Logger.debug(
        "Spawning buffered Reflector Task for session #{state.session_id} with #{state.observation_tokens} tokens (epoch #{state.activation_epoch})"
      )

      # Emit buffering_started event
      broadcast_event(state.session_id, {:om, :buffering_started, %{type: :reflection}})
      # Emit reflection_started event
      broadcast_event(state.session_id, {:om, :reflection_started, %{level: 0}})

      # Target size is 50% of reflection threshold (per spec section 4.3)
      target_size = div(@default_observation_threshold, 2)

      task_supervisor = Supervisor.task_supervisor_name(state.session_id)

      # Capture the current epoch - the Task result will be tagged with this epoch
      current_epoch = state.activation_epoch

      # Spawn Reflector Task
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          result =
            Reflector.run(
              state.config,
              state.active_observations,
              target_size,
              state.calibration_factor
            )

          # Tag the result with the epoch it was computed against
          Map.put(result, :epoch, current_epoch)
        end)

      %{
        state
        | is_buffering_reflection: true,
          reflector_ref: task.ref
      }
    end
  end

  defp spawn_reflector_task(state) do
    # Check circuit breaker before spawning
    if not can_attempt_cycle?(state) do
      Logger.debug(
        "Skipping Reflector spawn for session #{state.session_id} - circuit breaker is open"
      )

      state
    else
      # Reset circuit if cooldown has expired
      state = if state.circuit_open, do: reset_circuit(state), else: state

      Logger.debug(
        "Spawning Reflector Task for session #{state.session_id} with #{state.observation_tokens} tokens"
      )

      # Emit reflection_started event (level starts at 0)
      broadcast_event(state.session_id, {:om, :reflection_started, %{level: 0}})

      # Target size is 50% of reflection threshold (per spec section 4.3)
      target_size = div(@default_observation_threshold, 2)

      task_supervisor = Supervisor.task_supervisor_name(state.session_id)

      # Spawn Reflector Task
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          Reflector.run(
            state.config,
            state.active_observations,
            target_size,
            state.calibration_factor
          )
        end)

      %{
        state
        | is_reflecting: true,
          reflector_ref: task.ref
      }
    end
  end

  ## Circuit Breaker Functions

  defp broadcast_event(session_id, event) do
    # Broadcast OM event via Registry for TUI and other consumers
    Registry.dispatch(Deft.Registry, {:session, session_id}, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:om_event, event})
      end
    end)
  end

  defp record_cycle_success(state) do
    # Reset consecutive failures on successful cycle
    %{state | consecutive_failures: 0}
  end

  defp record_cycle_failure(state, type, reason) do
    # Increment consecutive failures
    new_failures = state.consecutive_failures + 1

    # Emit cycle_failed event
    broadcast_event(state.session_id, {:om, :cycle_failed, %{type: type, reason: reason}})

    # Check if we should open the circuit
    state = %{state | consecutive_failures: new_failures}

    if should_open_circuit?(state) do
      open_circuit(state)
    else
      state
    end
  end

  defp should_open_circuit?(state) do
    state.consecutive_failures >= 3 and not state.circuit_open
  end

  defp open_circuit(state) do
    Logger.warning(
      "OM circuit breaker opened for session #{state.session_id} after 3 consecutive failures"
    )

    # Emit circuit_open event
    broadcast_event(state.session_id, {:om, :circuit_open})

    %{
      state
      | circuit_open: true,
        circuit_opened_at: DateTime.utc_now()
    }
  end

  defp can_attempt_cycle?(state) do
    cond do
      # Circuit is not open - can attempt
      not state.circuit_open ->
        true

      # Circuit is open - check cooldown (5 minutes)
      state.circuit_open and state.circuit_opened_at != nil ->
        elapsed_seconds = DateTime.diff(DateTime.utc_now(), state.circuit_opened_at, :second)
        cooldown_seconds = 5 * 60

        if elapsed_seconds >= cooldown_seconds do
          Logger.info(
            "OM circuit breaker cooldown expired for session #{state.session_id}, resuming"
          )

          true
        else
          false
        end

      # Shouldn't happen, but treat as circuit open
      true ->
        false
    end
  end

  defp reset_circuit(state) do
    # Reset circuit breaker state (called after successful cooldown)
    %{
      state
      | circuit_open: false,
        circuit_opened_at: nil,
        consecutive_failures: 0
    }
  end

  ## Hard Observation Cap (Spec Section 4.6)

  # Hard cap threshold: 1.5x reflection threshold = 60,000 tokens
  @hard_cap_threshold 60_000

  defp maybe_apply_hard_cap(state) do
    if state.observation_tokens > @hard_cap_threshold do
      apply_hard_cap(state)
    else
      state
    end
  end

  defp apply_hard_cap(state) do
    Logger.warning(
      "OM hard cap exceeded for session #{state.session_id}: #{state.observation_tokens} > #{@hard_cap_threshold} tokens, truncating Session History"
    )

    before_tokens = state.observation_tokens

    # Parse observations into sections
    sections = Parse.parse_sections(state.active_observations)

    # Extract CORRECTION markers from entire observations (must preserve all)
    correction_markers = extract_all_correction_markers(state.active_observations)

    # Get Session History section
    session_history = Map.get(sections, "Session History", "")

    # Calculate tokens for all other sections (everything except Session History)
    other_sections_tokens =
      sections
      |> Map.delete("Session History")
      |> Enum.map(fn {name, content} ->
        Tokens.estimate("## #{name}\n#{content}", state.calibration_factor)
      end)
      |> Enum.sum()

    # Add overhead for section separators (2 newlines between sections)
    num_sections = map_size(sections)
    separator_tokens = Tokens.estimate("\n\n", state.calibration_factor) * (num_sections - 1)

    # Calculate target Session History size
    # Use 95% of remaining space to account for token estimation inaccuracies
    available_tokens = @hard_cap_threshold - other_sections_tokens - separator_tokens
    target_history_tokens = max(0, trunc(available_tokens * 0.95))

    # Truncate Session History from the head (oldest entries) until under target
    truncated_history =
      truncate_session_history_to_target(
        session_history,
        target_history_tokens,
        correction_markers,
        state.calibration_factor
      )

    # Replace Session History section with truncated version
    updated_sections = Map.put(sections, "Session History", truncated_history)

    # Reconstruct observations in canonical order
    new_observations = reconstruct_observations(updated_sections)

    # Calculate new token count
    after_tokens = Tokens.estimate(new_observations, state.calibration_factor)

    # Emit hard cap truncation event
    broadcast_event(state.session_id, {
      :om,
      :hard_cap_truncation,
      %{before: before_tokens, after: after_tokens}
    })

    Logger.info(
      "OM hard cap truncation complete for session #{state.session_id}: #{before_tokens} -> #{after_tokens} tokens"
    )

    # Update state with truncated observations
    %{
      state
      | active_observations: new_observations,
        observation_tokens: after_tokens,
        snapshot_dirty: true
    }
  end

  # Extract all CORRECTION markers from observations
  defp extract_all_correction_markers(observations) do
    observations
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "CORRECTION:"))
    |> Enum.map(&String.trim/1)
  end

  # Truncate Session History from the head until it fits within target token count
  # Preserve CORRECTION markers by moving them to the end
  defp truncate_session_history_to_target(
         session_history,
         target_tokens,
         correction_markers,
         calibration_factor
       ) do
    lines = String.split(session_history, "\n", trim: true)

    # Separate CORRECTION markers from regular lines
    {correction_lines, regular_lines} =
      Enum.split_with(lines, fn line ->
        Enum.any?(correction_markers, fn marker ->
          String.contains?(line, marker)
        end)
      end)

    # Calculate tokens for CORRECTION markers (these must be kept)
    correction_tokens =
      correction_lines
      |> Enum.map(&Tokens.estimate(&1, calibration_factor))
      |> Enum.sum()

    # Calculate available tokens for regular lines
    available_for_regular = max(0, target_tokens - correction_tokens)

    # Keep as many recent lines as possible within the available tokens
    # Process from end (most recent) to beginning (oldest)
    {kept_lines, _accumulated_tokens} =
      regular_lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn line, {kept, tokens_so_far} ->
        line_tokens = Tokens.estimate(line, calibration_factor)

        if tokens_so_far + line_tokens <= available_for_regular do
          # Can keep this line
          {:cont, {[line | kept], tokens_so_far + line_tokens}}
        else
          # Exceeded budget, halt processing
          {:halt, {kept, tokens_so_far}}
        end
      end)

    # Reconstruct Session History: kept lines + CORRECTION markers at end
    all_lines = kept_lines ++ correction_lines

    Enum.join(all_lines, "\n")
  end

  # Reconstruct observations from sections in canonical order
  defp reconstruct_observations(sections) do
    # Section order from Parse module
    section_order = [
      "Current State",
      "User Preferences",
      "Files & Architecture",
      "Decisions",
      "Session History"
    ]

    section_order
    |> Enum.map(fn section_name ->
      case Map.get(sections, section_name) do
        nil ->
          nil

        "" ->
          nil

        content ->
          "## #{section_name}\n#{content}"
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  ## Snapshot Persistence Functions

  # Schedule the next snapshot timer (60 seconds)
  defp schedule_snapshot_timer do
    Process.send_after(self(), :snapshot_timer, 60_000)
  end

  # Write an OM snapshot to the separate OM snapshot file
  # Per spec section 9.1, called:
  # - After each observation activation
  # - After each reflection activation
  # - Every 60 seconds if snapshot_dirty
  # - On session shutdown
  defp write_snapshot(state) do
    # Create snapshot entry with all persisted fields from spec section 9.2
    entry =
      ObservationEntry.new(
        state.active_observations,
        state.observation_tokens,
        state.observed_message_ids,
        state.pending_message_tokens,
        state.generation_count,
        state.last_observed_at,
        state.activation_epoch,
        state.calibration_factor
      )

    # Write to separate OM snapshot file to avoid JSONL write interleaving
    path = om_snapshot_path(state.session_id)

    with :ok <- ensure_sessions_dir(),
         {:ok, json} <- Jason.encode(entry),
         line <- json <> "\n",
         :ok <- File.write(path, line, [:append]) do
      Logger.debug("OM snapshot written for session #{state.session_id}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to write OM snapshot for session #{state.session_id}: #{inspect(reason)}"
        )

        error
    end
  end

  # Path to the OM snapshot file (separate from session JSONL)
  defp om_snapshot_path(session_id) do
    sessions_dir = Path.expand("~/.deft/sessions")
    Path.join(sessions_dir, "#{session_id}_om.jsonl")
  end

  defp ensure_sessions_dir do
    sessions_dir = Path.expand("~/.deft/sessions")

    case File.mkdir_p(sessions_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse a single line from the OM snapshot file
  defp parse_snapshot_line(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, data} ->
        # Deserialize into ObservationEntry struct
        %ObservationEntry{
          type: :observation,
          active_observations: data.active_observations,
          observation_tokens: data.observation_tokens,
          observed_message_ids: data.observed_message_ids,
          pending_message_tokens: data[:pending_message_tokens] || 0,
          generation_count: data.generation_count,
          last_observed_at: parse_datetime_or_nil(data[:last_observed_at]),
          activation_epoch: data[:activation_epoch] || 0,
          calibration_factor: data[:calibration_factor] || 4.0,
          timestamp: parse_datetime(data.timestamp)
        }

      {:error, reason} ->
        Logger.warning("Failed to parse OM snapshot line: #{inspect(reason)}")
        nil
    end
  end

  # Parse DateTime from string or pass through DateTime struct
  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  # Parse DateTime or return nil for missing values
  defp parse_datetime_or_nil(nil), do: nil

  defp parse_datetime_or_nil(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime_or_nil(%DateTime{} = dt), do: dt
end
