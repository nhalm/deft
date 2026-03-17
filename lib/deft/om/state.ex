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
  alias Deft.OM.{BufferedChunk, Observer, Supervisor, Tokens}
  alias Deft.OM.Observer.Parse

  # Default thresholds from spec section 8
  @default_message_threshold 30_000
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
          last_buffer_threshold: integer()
        }

  @enforce_keys [:session_id, :config]
  defstruct [
    :session_id,
    :config,
    :observer_ref,
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
    {:via, Registry, {Deft.ProcessRegistry, {:om_state, session_id}}}
  end

  defp check_and_spawn_observer(state) do
    buffer_size = trunc(@default_message_threshold * @default_buffer_interval)
    current_threshold = div(state.pending_message_tokens, buffer_size) * buffer_size

    # First, check if we should activate buffered chunks
    state =
      if state.pending_message_tokens >= @default_message_threshold and
           not Enum.empty?(state.buffered_chunks) do
        activate_buffered_chunks(state)
      else
        state
      end

    # Then check if we should spawn observer for buffering
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

    %{
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
  end
end
