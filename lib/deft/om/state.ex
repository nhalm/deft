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

  alias Deft.OM.{BufferedChunk, Supervisor, Tokens}

  # Default thresholds from spec section 8
  @default_message_threshold 30_000
  @default_buffer_interval 0.2

  @type t :: %__MODULE__{
          session_id: String.t(),
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
          last_buffer_threshold: integer()
        }

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    :observer_ref,
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
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
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

  Accepts a list of message metadata maps with `:id` and `:tokens` keys.
  Updates pending_message_tokens and spawns Observer Tasks when buffer intervals are crossed.
  """
  @spec messages_added(String.t(), [%{id: String.t(), tokens: integer()}]) :: :ok
  def messages_added(session_id, messages) do
    GenServer.cast(via_tuple(session_id), {:messages_added, messages})
  end

  ## Server Callbacks

  @impl true
  def init(session_id) do
    Logger.debug("Starting OM State for session #{session_id}")
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, {state.active_observations, state.observed_message_ids}, state}
  end

  @impl true
  def handle_cast({:messages_added, messages}, state) do
    # Calculate new pending tokens
    new_tokens = Enum.reduce(messages, 0, fn msg, acc -> acc + msg.tokens end)
    new_pending = state.pending_message_tokens + new_tokens

    # Check if we crossed a buffer interval threshold
    state = check_and_spawn_observer(%{state | pending_message_tokens: new_pending})

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, %{observer_ref: ref} = state) when ref != nil do
    # Observer Task completed successfully
    Logger.debug("Observer Task completed for session #{state.session_id}")

    # Demonitor the task
    Process.demonitor(ref, [:flush])

    # Store the buffered chunk
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

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{observer_ref: ref} = state)
      when ref != nil do
    # Observer Task crashed or failed
    Logger.warning("Observer Task failed for session #{state.session_id}: #{inspect(reason)}")

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
    {:via, Registry, {Deft.Registry, {:om_state, session_id}}}
  end

  defp check_and_spawn_observer(state) do
    buffer_size = trunc(@default_message_threshold * @default_buffer_interval)
    current_threshold = div(state.pending_message_tokens, buffer_size) * buffer_size

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

    # TODO: Replace with actual Observer call when Observer module is implemented
    # For now, spawn a dummy task that returns empty observations
    task_supervisor = Supervisor.task_supervisor_name(state.session_id)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        # Placeholder - will be replaced with actual Observer.run/2 call
        %{
          observations: "",
          message_ids: [],
          message_tokens: 0
        }
      end)

    %{
      state
      | is_observing: true,
        observer_ref: task.ref,
        last_buffer_threshold: threshold
    }
  end
end
