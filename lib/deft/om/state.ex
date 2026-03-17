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
          last_buffer_threshold: integer()
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
    last_observed_at: nil,
    observed_message_ids: [],
    pending_message_tokens: 0,
    generation_count: 0,
    is_observing: false,
    is_reflecting: false,
    needs_rebuffer: false,
    activation_epoch: 0,
    snapshot_dirty: false,
    calibration_factor: 4.0,
    sync_from: nil,
    last_buffer_threshold: 0
  ]

  ## Client API

  @doc """
  Starts the OM State GenServer for the given session.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    GenServer.start_link(__MODULE__, {session_id, config}, name: via_tuple(session_id))
  end

  @doc """
  Returns the current observation context for injection into the Agent's context.

  Returns `{observations_text, observed_message_ids}`.
  """
  @spec get_context(String.t()) :: {String.t(), [String.t()]}
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

  ## Server Callbacks

  @impl true
  def init({session_id, config}) do
    Logger.debug("Starting OM State for session #{session_id}")
    {:ok, %__MODULE__{session_id: session_id, config: config}}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, {state.active_observations, state.observed_message_ids}, state}
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

    # Check if this is a sync fallback call
    if state.sync_from do
      # Reply to the stashed caller with the result
      GenServer.reply(state.sync_from, {:ok, result})

      # Clear sync_from and flags
      state = %{
        state
        | sync_from: nil,
          is_observing: false,
          observer_ref: nil
      }

      {:noreply, state}
    else
      # Normal async buffering path - store the buffered chunk
      chunk = %BufferedChunk{
        observations: result.observations,
        token_count: Tokens.estimate(result.observations, state.calibration_factor),
        message_ids: result.message_ids,
        message_tokens: result.message_tokens,
        epoch: state.activation_epoch
      }

      state = %{
        state
        | buffered_chunks: state.buffered_chunks ++ [chunk],
          is_observing: false,
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

    # After Reflector completes, check if there are buffered chunks to activate
    # (now that is_reflecting is false)
    state =
      if not Enum.empty?(state.buffered_chunks) and
           state.pending_message_tokens >= @default_message_threshold do
        activate_buffered_chunks(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reflector_ref: ref} = state)
      when ref != nil do
    # Reflector Task crashed or failed
    Logger.warning("Reflector Task failed for session #{state.session_id}: #{inspect(reason)}")

    state = %{
      state
      | is_reflecting: false,
        reflector_ref: nil
    }

    {:noreply, state}
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

  ## Private Functions

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
    Logger.debug(
      "Spawning Observer Task for session #{state.session_id} at #{state.pending_message_tokens} tokens"
    )

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

  defp activate_buffered_chunks(state) do
    Logger.info(
      "Activating #{length(state.buffered_chunks)} buffered chunks for session #{state.session_id}"
    )

    # Section-aware merge all chunks into active_observations
    merged_observations =
      Enum.reduce(state.buffered_chunks, state.active_observations, fn chunk, acc ->
        Parse.merge_observations(acc, chunk.observations)
      end)

    # Collect all message_ids from all chunks
    all_message_ids =
      Enum.flat_map(state.buffered_chunks, fn chunk -> chunk.message_ids end)

    # Add chunk message_ids to observed_message_ids
    new_observed_message_ids = state.observed_message_ids ++ all_message_ids

    # Calculate tokens for merged observations
    new_observation_tokens = Tokens.estimate(merged_observations, state.calibration_factor)

    # Calculate how many tokens were observed (to subtract from pending)
    observed_tokens =
      Enum.reduce(state.buffered_chunks, 0, fn chunk, acc -> acc + chunk.message_tokens end)

    # Subtract observed tokens from pending
    new_pending = max(0, state.pending_message_tokens - observed_tokens)

    state = %{
      state
      | active_observations: merged_observations,
        observation_tokens: new_observation_tokens,
        buffered_chunks: [],
        observed_message_ids: new_observed_message_ids,
        pending_message_tokens: new_pending,
        activation_epoch: state.activation_epoch + 1,
        snapshot_dirty: true,
        last_observed_at: DateTime.utc_now()
    }

    # Check if we should trigger reflection
    check_and_spawn_reflector(state)
  end

  defp check_and_spawn_reflector(state) do
    # Check if observation_tokens exceeds reflection threshold
    # Only spawn if not already reflecting and not currently observing (serialization)
    if state.observation_tokens >= @default_observation_threshold and
         not state.is_reflecting and
         not state.is_observing do
      spawn_reflector_task(state)
    else
      state
    end
  end

  defp spawn_reflector_task(state) do
    Logger.debug(
      "Spawning Reflector Task for session #{state.session_id} with #{state.observation_tokens} tokens"
    )

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
