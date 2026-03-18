defmodule Deft.Store do
  @moduledoc """
  GenServer that wraps ETS (fast in-memory reads) backed by DETS (disk persistence).

  One module, multiple instances with different configurations:
  - **Cache** — tool result spilling, session-scoped, Lead-isolated, lazy writes
  - **Site Log** — curated job knowledge, job-scoped, Foreman-write only, sync writes

  ETS handles reads (concurrent, no process bottleneck). DETS handles persistence
  (async writes, crash recovery). The GenServer manages access control, lifecycle,
  and write policies.

  ## Directory Layout

      ~/.deft/projects/<path-encoded-repo>/
        cache/<session_id>/lead-<lead_id>.dets       # Cache instances
        jobs/<job_id>/sitelog.dets                    # Site Log instances

  ## Instance Types

  ### Cache Instance

  - Started per Lead, per session
  - Session-scoped, ephemeral
  - Writer: owning Lead (via tools)
  - Readers: owning Lead, Foreman
  - Write policy: lazy/batched (5s or 50 entries)
  - No :dets.sync/1 after flush (loss on crash is acceptable)

  ### Site Log Instance

  - Started per job (if orchestrated)
  - Job lifetime
  - Writer: Foreman only (enforced via Registry-resolved name)
  - Readers: Leads (read-only via tid)
  - Write policy: synchronous with :dets.sync/1

  ## Registration

  Instances are registered via `{:via, Registry, {Deft.ProcessRegistry, name}}`:

  - Cache: `{:cache, session_id, lead_id}`
  - Site Log: `{:sitelog, job_id}`

  ## API

      # Write (goes through GenServer for access control + DETS queue)
      Deft.Store.write(server, key, value, metadata)  # => :ok | {:error, reason}

      # Read (direct ETS lookup by tid, no GenServer call)
      Deft.Store.read(tid, key)                       # => {:ok, entry} | :miss

      # Delete (goes through GenServer)
      Deft.Store.delete(server, key)                  # => :ok

      # List keys (direct ETS lookup by tid)
      Deft.Store.keys(tid)                            # => [key]

      # Get ETS tid for direct reads
      Deft.Store.tid(server)                          # => tid

      # Cleanup (flush + close + delete)
      Deft.Store.cleanup(server)                      # => :ok
  """

  use GenServer
  require Logger

  @type instance_type :: :cache | :sitelog
  @type name :: {:cache, String.t(), String.t()} | {:sitelog, String.t()}
  @type entry :: %{value: term(), metadata: map()}

  # Client API

  @doc """
  Starts a Deft.Store instance.

  ## Options

    * `:name` - Registry name tuple (required)
    * `:type` - `:cache` or `:sitelog` (required)
    * `:dets_path` - Path to DETS file (required)
    * `:owner_name` - For sitelog: Foreman's registered name for access control
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    via_name = {:via, Registry, {Deft.ProcessRegistry, name}}
    GenServer.start_link(__MODULE__, opts, name: via_name)
  end

  @doc """
  Writes an entry to the store.

  For cache instances, any caller can write.
  For site log instances, only the owner (Foreman) can write.

  Returns `:ok` or `{:error, :unauthorized}`.
  """
  def write(server, key, value, metadata \\ %{}) do
    GenServer.call(server, {:write, key, value, metadata, self()})
  end

  @doc """
  Reads an entry from the store by direct ETS lookup.

  Returns `{:ok, entry}` or `:miss`.

  Wraps ETS access in try/rescue to handle table-owner crash gracefully.
  """
  def read(tid, key) do
    try do
      case :ets.lookup(tid, key) do
        [{^key, entry}] -> {:ok, entry}
        [] -> :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  @doc """
  Deletes an entry from the store.
  """
  def delete(server, key) do
    GenServer.call(server, {:delete, key})
  end

  @doc """
  Lists all keys in the store by direct ETS lookup.
  """
  def keys(tid) do
    try do
      :ets.select(tid, [{{:"$1", :_}, [], [:"$1"]}])
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Returns the ETS tid for direct reads.
  """
  def tid(server) do
    GenServer.call(server, :tid)
  end

  @doc """
  Cleans up the store: flushes buffered writes, closes DETS, deletes file, deletes ETS table.
  """
  def cleanup(server) do
    GenServer.call(server, :cleanup)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    type = Keyword.fetch!(opts, :type)
    dets_path = Keyword.fetch!(opts, :dets_path)
    owner_name = Keyword.get(opts, :owner_name)

    # Ensure parent directory exists
    dets_path |> Path.dirname() |> File.mkdir_p!()

    # Open DETS file with error fallback
    dets_file = open_dets_file(dets_path, type)

    # Create unnamed ETS table (:set, :protected)
    # Only the owner (this GenServer) can write. Other processes can read.
    tid = :ets.new(:store_table, [:set, :protected])

    state = %{
      type: type,
      tid: tid,
      dets_file: dets_file,
      dets_path: dets_path,
      owner_name: owner_name,
      write_buffer: [],
      loading: true,
      closed: false,
      flush_timer: schedule_flush_timer(type)
    }

    # Load DETS into ETS asynchronously via handle_continue
    # This keeps init fast while allowing the owner process to write to :protected ETS
    {:ok, state, {:continue, :load_dets}}
  end

  @impl true
  def handle_call({:write, key, value, metadata, caller_pid}, _from, state) do
    # Access control for site log
    if state.type == :sitelog do
      case validate_site_log_writer(caller_pid, state.owner_name) do
        :ok -> do_write(key, value, metadata, state)
        error -> {:reply, error, state}
      end
    else
      # Cache: anyone can write
      do_write(key, value, metadata, state)
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    # Delete from ETS immediately
    :ets.delete(state.tid, key)

    # Queue DETS delete
    new_buffer = [{:delete, key} | state.write_buffer]
    new_state = %{state | write_buffer: new_buffer}

    # For sitelog: flush immediately and sync
    # For cache: flush if buffer is full
    new_state =
      if state.type == :sitelog do
        flush_buffer(new_state, sync: true)
      else
        maybe_flush_buffer(new_state)
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:tid, _from, state) do
    {:reply, state.tid, state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    new_state = do_cleanup(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_continue(:load_dets, state) do
    # Load DETS into ETS synchronously in the owner process
    # This allows writing to :protected ETS table
    load_dets_to_ets(state.dets_file, state.tid)
    {:noreply, %{state | loading: false}}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    new_state = flush_buffer(state)
    new_state = %{new_state | flush_timer: schedule_flush_timer(state.type)}
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    # Check closed flag to prevent double-flush/close
    if not state.closed do
      do_shutdown(state)
    end

    :ok
  end

  # Private Functions

  defp open_dets_file(path, type) do
    case :dets.open_file(String.to_charlist(path), type: :set) do
      {:ok, dets_file} ->
        dets_file

      {:error, reason} ->
        # Fall back to creating a new empty DETS file
        if type == :sitelog do
          Logger.warning(
            "Deft.Store: site log DETS corruption at #{path}, creating new file: #{inspect(reason)}"
          )
        end

        # Delete corrupted file if it exists
        File.rm(path)

        # Create new DETS file
        {:ok, dets_file} = :dets.open_file(String.to_charlist(path), type: :set)
        dets_file
    end
  end

  defp load_dets_to_ets(dets_file, tid) do
    :dets.foldl(
      fn {key, entry}, acc ->
        :ets.insert(tid, {key, entry})
        acc
      end,
      :ok,
      dets_file
    )
  end

  defp validate_site_log_writer(caller_pid, owner_name) when is_tuple(owner_name) do
    # Resolve registered name to PID
    case Registry.lookup(Deft.ProcessRegistry, owner_name) do
      [{owner_pid, _}] when owner_pid == caller_pid ->
        :ok

      _ ->
        {:error, :unauthorized}
    end
  end

  defp validate_site_log_writer(_caller_pid, nil) do
    # No owner_name configured, allow writes (testing scenario)
    :ok
  end

  defp do_write(key, value, metadata, state) do
    entry = %{value: value, metadata: metadata}

    # Write to ETS immediately
    :ets.insert(state.tid, {key, entry})

    # Queue for DETS flush
    new_buffer = [{:write, key, entry} | state.write_buffer]
    new_state = %{state | write_buffer: new_buffer}

    # For sitelog: flush immediately and sync
    # For cache: flush if buffer is full
    new_state =
      if state.type == :sitelog do
        flush_buffer(new_state, sync: true)
      else
        maybe_flush_buffer(new_state)
      end

    {:reply, :ok, new_state}
  end

  defp maybe_flush_buffer(state) do
    # Flush if buffer reaches 50 entries (cache only)
    if length(state.write_buffer) >= 50 do
      flush_buffer(state)
    else
      state
    end
  end

  defp flush_buffer(state, opts \\ []) do
    # Write all buffered operations to DETS
    Enum.each(Enum.reverse(state.write_buffer), fn
      {:write, key, entry} ->
        :dets.insert(state.dets_file, {key, entry})

      {:delete, key} ->
        :dets.delete(state.dets_file, key)
    end)

    # Sync DETS if requested (sitelog only)
    if Keyword.get(opts, :sync, false) do
      :dets.sync(state.dets_file)
    end

    %{state | write_buffer: []}
  end

  defp schedule_flush_timer(:cache) do
    # Flush every 5 seconds for cache
    Process.send_after(self(), :flush_buffer, 5000)
  end

  defp schedule_flush_timer(:sitelog) do
    # No periodic flush for sitelog (writes are immediate)
    nil
  end

  defp do_shutdown(state) do
    # Graceful shutdown - flush and close but don't delete
    # Set closed flag
    state = %{state | closed: true}

    # Cancel flush timer if active
    if state.flush_timer do
      Process.cancel_timer(state.flush_timer)
    end

    # Flush buffered writes
    state = flush_buffer(state)

    # Close DETS
    :dets.close(state.dets_file)

    # Delete ETS table
    :ets.delete(state.tid)

    state
  end

  defp do_cleanup(state) do
    # Full cleanup - shutdown + delete files
    state = do_shutdown(state)

    # Delete DETS file
    if File.exists?(state.dets_path) do
      File.rm(state.dets_path)
    end

    state
  end
end
