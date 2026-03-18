defmodule Deft.Issues do
  @moduledoc """
  GenServer that manages persistent issue tracking for Deft.

  Issues are stored as JSONL in `.deft/issues.jsonl` and loaded into memory
  on startup. All writes serialize through this GenServer.

  ## Features

  - JSONL storage with dedup-on-read (last occurrence wins)
  - Cycle detection on load (clears dependencies with warnings)
  - In-memory state (list of Issue structs)
  - Atomic file writes with advisory locking
  - Worktree awareness (resolves to main repo)
  """

  use GenServer
  require Logger

  alias Deft.Git
  alias Deft.Issue
  alias Deft.Issue.Id

  @typedoc "GenServer state containing all issues"
  @type state :: %{
          issues: [Issue.t()],
          file_path: String.t()
        }

  ## Client API

  @doc """
  Starts the Issues GenServer.

  ## Options

  - `:file_path` - Path to issues.jsonl file (optional, defaults to .deft/issues.jsonl)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new issue.

  ## Parameters

  - `attrs` - Map with issue attributes. Required: `:title`, `:source`. Optional: `:context`,
    `:acceptance_criteria`, `:constraints`, `:priority`, `:dependencies`.

  ## Returns

  `{:ok, issue}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Deft.Issues.create(%{title: "Fix bug", source: :user})
      {:ok, %Deft.Issue{id: "deft-a1b2", ...}}
  """
  def create(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:create, attrs})
  end

  @doc """
  Updates an existing issue.

  ## Parameters

  - `id` - Issue ID
  - `attrs` - Map with attributes to update

  ## Returns

  `{:ok, issue}` on success, `{:error, reason}` on failure.
  """
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:update, id, attrs})
  end

  @doc """
  Closes an issue.

  Sets status to `:closed` and records `closed_at` timestamp.

  ## Parameters

  - `id` - Issue ID
  - `job_id` - Optional job ID that closed this issue

  ## Returns

  `{:ok, issue}` on success, `{:error, reason}` on failure.
  """
  def close(id, job_id \\ nil) when is_binary(id) do
    GenServer.call(__MODULE__, {:close, id, job_id})
  end

  @doc """
  Gets an issue by ID.

  ## Returns

  `{:ok, issue}` if found, `{:error, :not_found}` otherwise.
  """
  def get(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Lists issues matching the given filters.

  ## Options

  - `:status` - Filter by status (`:open`, `:in_progress`, `:closed`, or list of statuses)
  - `:priority` - Filter by priority (0-4)

  ## Returns

  List of issues matching the filters. Defaults to open and in_progress issues.
  """
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Returns ready issues (open, with all dependencies closed).

  Ready issues are sorted by priority (0 first), then by created_at (oldest first).

  ## Returns

  List of ready issues.
  """
  def ready do
    GenServer.call(__MODULE__, :ready)
  end

  @doc """
  Returns blocked issues (open, with at least one non-closed dependency).

  ## Returns

  List of blocked issues.
  """
  def blocked do
    GenServer.call(__MODULE__, :blocked)
  end

  @doc """
  Adds a dependency to an issue.

  ## Parameters

  - `issue_id` - ID of the issue to modify
  - `blocker_id` - ID of the issue that blocks this one

  ## Returns

  `{:ok, issue}` on success, `{:error, reason}` on failure.
  Errors include `:not_found`, `:cycle_detected`, and `:blocker_not_found`.

  ## Examples

      iex> Deft.Issues.add_dependency("deft-a1b2", "deft-c3d4")
      {:ok, %Deft.Issue{dependencies: ["deft-c3d4"], ...}}
  """
  def add_dependency(issue_id, blocker_id) when is_binary(issue_id) and is_binary(blocker_id) do
    GenServer.call(__MODULE__, {:add_dependency, issue_id, blocker_id})
  end

  @doc """
  Removes a dependency from an issue.

  ## Parameters

  - `issue_id` - ID of the issue to modify
  - `blocker_id` - ID of the blocker to remove

  ## Returns

  `{:ok, issue}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Deft.Issues.remove_dependency("deft-a1b2", "deft-c3d4")
      {:ok, %Deft.Issue{dependencies: [], ...}}
  """
  def remove_dependency(issue_id, blocker_id)
      when is_binary(issue_id) and is_binary(blocker_id) do
    GenServer.call(__MODULE__, {:remove_dependency, issue_id, blocker_id})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    file_path = Keyword.get(opts, :file_path, resolve_file_path())
    compaction_days = Keyword.get(opts, :compaction_days, 90)

    # Load issues from JSONL file
    issues = load_issues(file_path)

    # Compact old closed issues
    issues = compact_closed_issues(issues, compaction_days, file_path)

    # Detect and fix cycles
    issues = detect_and_fix_cycles(issues, file_path)

    {:ok, %{issues: issues, file_path: file_path}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    timestamp = Issue.timestamp()
    existing_ids = Enum.map(state.issues, & &1.id)
    id = Id.generate(existing_ids)

    source = Map.fetch!(attrs, :source)
    # Default priority depends on source: agent defaults to 3 (low), user defaults to 2 (medium)
    default_priority = if source == :agent, do: 3, else: 2

    issue = %Issue{
      id: id,
      title: Map.fetch!(attrs, :title),
      context: Map.get(attrs, :context, ""),
      acceptance_criteria: Map.get(attrs, :acceptance_criteria, []),
      constraints: Map.get(attrs, :constraints, []),
      status: :open,
      priority: Map.get(attrs, :priority, default_priority),
      dependencies: Map.get(attrs, :dependencies, []),
      created_at: timestamp,
      updated_at: timestamp,
      closed_at: nil,
      source: source,
      job_id: nil
    }

    # Check for cycles
    with {:ok, _} <- check_cycle(issue, state.issues),
         new_issues = [issue | state.issues],
         new_state = %{state | issues: new_issues},
         :ok <- persist_issues(new_state) do
      {:reply, {:ok, issue}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update, id, attrs}, _from, state) do
    case find_issue_index(state.issues, id) do
      nil -> {:reply, {:error, :not_found}, state}
      index -> do_update(index, attrs, state)
    end
  end

  @impl true
  def handle_call({:close, id, job_id}, _from, state) do
    case find_issue_index(state.issues, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        issue = Enum.at(state.issues, index)
        timestamp = Issue.timestamp()

        updated_issue = %{
          issue
          | status: :closed,
            closed_at: timestamp,
            updated_at: timestamp,
            job_id: job_id
        }

        new_issues = List.replace_at(state.issues, index, updated_issue)
        new_state = %{state | issues: new_issues}

        case persist_issues(new_state) do
          :ok -> {:reply, {:ok, updated_issue}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case Enum.find(state.issues, &(&1.id == id)) do
      nil -> {:reply, {:error, :not_found}, state}
      issue -> {:reply, {:ok, issue}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    status_filter = Keyword.get(opts, :status, [:open, :in_progress])
    priority_filter = Keyword.get(opts, :priority)

    # Normalize status filter to list
    status_filter =
      cond do
        is_list(status_filter) -> status_filter
        is_atom(status_filter) -> [status_filter]
        true -> [:open, :in_progress]
      end

    filtered =
      state.issues
      |> Enum.filter(&(&1.status in status_filter))
      |> then(fn issues ->
        if priority_filter do
          Enum.filter(issues, &(&1.priority == priority_filter))
        else
          issues
        end
      end)

    {:reply, filtered, state}
  end

  @impl true
  def handle_call(:ready, _from, state) do
    ready_issues =
      state.issues
      |> Enum.filter(&is_ready?(&1, state.issues))
      |> Enum.sort_by(&{&1.priority, &1.created_at})

    {:reply, ready_issues, state}
  end

  @impl true
  def handle_call(:blocked, _from, state) do
    blocked_issues =
      state.issues
      |> Enum.filter(&is_blocked?(&1, state.issues))

    {:reply, blocked_issues, state}
  end

  @impl true
  def handle_call({:add_dependency, issue_id, blocker_id}, _from, state) do
    with {:ok, _} <- validate_issue_exists(state.issues, issue_id),
         {:ok, _} <- validate_blocker_exists(state.issues, blocker_id),
         index when not is_nil(index) <- find_issue_index(state.issues, issue_id) do
      issue = Enum.at(state.issues, index)
      updated_deps = Enum.uniq([blocker_id | issue.dependencies])
      updated_issue = %{issue | dependencies: updated_deps, updated_at: Issue.timestamp()}

      # Check for cycles with the updated dependency list
      case check_cycle(updated_issue, List.delete_at(state.issues, index)) do
        {:ok, _} ->
          new_issues = List.replace_at(state.issues, index, updated_issue)
          new_state = %{state | issues: new_issues}

          case persist_issues(new_state) do
            :ok -> {:reply, {:ok, updated_issue}, new_state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        {:error, :cycle_detected} ->
          {:reply, {:error, :cycle_detected}, state}
      end
    else
      {:error, :not_found} -> {:reply, {:error, :not_found}, state}
      {:error, :blocker_not_found} -> {:reply, {:error, :blocker_not_found}, state}
      nil -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove_dependency, issue_id, blocker_id}, _from, state) do
    case find_issue_index(state.issues, issue_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        issue = Enum.at(state.issues, index)
        updated_deps = Enum.reject(issue.dependencies, &(&1 == blocker_id))
        updated_issue = %{issue | dependencies: updated_deps, updated_at: Issue.timestamp()}

        new_issues = List.replace_at(state.issues, index, updated_issue)
        new_state = %{state | issues: new_issues}

        case persist_issues(new_state) do
          :ok -> {:reply, {:ok, updated_issue}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  ## Private Functions

  # Performs the actual update logic for an issue
  defp do_update(index, attrs, state) do
    issue = Enum.at(state.issues, index)
    updated_issue = build_updated_issue(issue, attrs)

    if Map.has_key?(attrs, :dependencies) do
      update_with_cycle_check(index, updated_issue, state)
    else
      update_without_cycle_check(index, updated_issue, state)
    end
  end

  # Builds an updated issue from existing issue and new attributes
  defp build_updated_issue(issue, attrs) do
    %{
      issue
      | title: Map.get(attrs, :title, issue.title),
        context: Map.get(attrs, :context, issue.context),
        acceptance_criteria: Map.get(attrs, :acceptance_criteria, issue.acceptance_criteria),
        constraints: Map.get(attrs, :constraints, issue.constraints),
        priority: Map.get(attrs, :priority, issue.priority),
        dependencies: Map.get(attrs, :dependencies, issue.dependencies),
        status: Map.get(attrs, :status, issue.status),
        updated_at: Issue.timestamp()
    }
  end

  # Updates an issue with cycle checking
  defp update_with_cycle_check(index, updated_issue, state) do
    with {:ok, _} <- check_cycle(updated_issue, List.delete_at(state.issues, index)),
         new_issues = List.replace_at(state.issues, index, updated_issue),
         new_state = %{state | issues: new_issues},
         :ok <- persist_issues(new_state) do
      {:reply, {:ok, updated_issue}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Updates an issue without cycle checking
  defp update_without_cycle_check(index, updated_issue, state) do
    new_issues = List.replace_at(state.issues, index, updated_issue)
    new_state = %{state | issues: new_issues}

    case persist_issues(new_state) do
      :ok -> {:reply, {:ok, updated_issue}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Resolves the issues.jsonl file path, accounting for worktrees
  defp resolve_file_path do
    case Git.cmd(["rev-parse", "--git-common-dir"]) do
      {output, 0} ->
        common_dir = String.trim(output)
        repo_root = Path.dirname(common_dir)
        Path.join([repo_root, ".deft", "issues.jsonl"])

      _error ->
        # Not in a git repo, use cwd
        Path.join([File.cwd!(), ".deft", "issues.jsonl"])
    end
  end

  # Loads issues from JSONL file with dedup-on-read
  defp load_issues(file_path) do
    if File.exists?(file_path) do
      file_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn line, acc ->
        case Issue.decode(line) do
          {:ok, issue} ->
            # Last occurrence wins (dedup-on-read)
            Map.put(acc, issue.id, issue)

          {:error, reason} ->
            Logger.warning("Skipping invalid JSON line in #{file_path}: #{inspect(reason)}")
            acc
        end
      end)
      |> Map.values()
    else
      []
    end
  end

  # Compacts closed issues older than the specified threshold
  defp compact_closed_issues(issues, compaction_days, file_path) do
    cutoff_date =
      DateTime.utc_now()
      |> DateTime.add(-compaction_days, :day)
      |> DateTime.to_iso8601()

    {compacted, remaining} =
      Enum.split_with(issues, fn issue ->
        issue.status == :closed && issue.closed_at != nil &&
          issue.closed_at < cutoff_date
      end)

    compacted_count = length(compacted)

    if compacted_count > 0 do
      Logger.info("Compacted #{compacted_count} closed issues older than #{compaction_days} days")

      # Rewrite the file without the compacted issues
      # We need to write directly here since we're in init/1, not in a handle_call
      case write_issues_during_init(remaining, file_path) do
        :ok ->
          remaining

        {:error, reason} ->
          Logger.warning("Failed to persist compacted issues: #{inspect(reason)}")
          issues
      end
    else
      issues
    end
  end

  # Writes issues during init (simpler than persist_issues, no locking needed during startup)
  defp write_issues_during_init(issues, file_path) do
    # Ensure directory exists
    File.mkdir_p!(Path.dirname(file_path))

    # Write to temp file
    temp_path = "#{file_path}.tmp.#{:erlang.unique_integer([:positive])}"

    try do
      lines =
        issues
        |> Enum.map(fn issue ->
          {:ok, json} = Issue.encode(issue)
          json <> "\n"
        end)

      File.write!(temp_path, lines)

      # Atomic rename
      File.rename!(temp_path, file_path)
      :ok
    rescue
      e ->
        # Clean up temp file on error
        File.rm(temp_path)
        {:error, e}
    end
  end

  # Detects cycles in dependency graph and clears dependencies with warnings
  defp detect_and_fix_cycles(issues, file_path) do
    {corrected_issues, cycles_found} =
      Enum.map_reduce(issues, false, fn issue, acc ->
        if has_cycle?(issue, issues, MapSet.new([issue.id])) do
          Logger.warning(
            "Cycle detected in dependencies for issue #{issue.id}. Clearing dependencies."
          )

          {%{issue | dependencies: []}, true}
        else
          {issue, acc}
        end
      end)

    # Persist corrected issues to disk if cycles were found
    if cycles_found do
      case write_issues_during_init(corrected_issues, file_path) do
        :ok ->
          corrected_issues

        {:error, reason} ->
          Logger.warning("Failed to persist cycle fixes: #{inspect(reason)}")
          corrected_issues
      end
    else
      corrected_issues
    end
  end

  # Checks if an issue has a cycle in its dependency graph
  defp has_cycle?(_issue, _all_issues, visited) when map_size(visited) > 100 do
    # Safety limit to prevent infinite recursion
    true
  end

  defp has_cycle?(issue, all_issues, visited) do
    Enum.any?(issue.dependencies, fn dep_id ->
      cond do
        MapSet.member?(visited, dep_id) ->
          true

        true ->
          case Enum.find(all_issues, &(&1.id == dep_id)) do
            nil -> false
            dep_issue -> has_cycle?(dep_issue, all_issues, MapSet.put(visited, dep_id))
          end
      end
    end)
  end

  # Checks if adding/updating an issue would create a cycle
  defp check_cycle(issue, other_issues) do
    all_issues = [issue | other_issues]

    if has_cycle?(issue, all_issues, MapSet.new([issue.id])) do
      {:error, :cycle_detected}
    else
      {:ok, issue}
    end
  end

  # Checks if an issue is ready (open with all dependencies closed)
  defp is_ready?(issue, all_issues) do
    issue.status == :open &&
      Enum.all?(issue.dependencies, fn dep_id ->
        case Enum.find(all_issues, &(&1.id == dep_id)) do
          nil -> true
          dep -> dep.status == :closed
        end
      end)
  end

  # Checks if an issue is blocked (open with at least one non-closed dependency)
  defp is_blocked?(issue, all_issues) do
    issue.status == :open &&
      Enum.any?(issue.dependencies, fn dep_id ->
        case Enum.find(all_issues, &(&1.id == dep_id)) do
          nil -> false
          dep -> dep.status in [:open, :in_progress]
        end
      end)
  end

  # Validates that an issue exists
  defp validate_issue_exists(issues, id) do
    case Enum.find(issues, &(&1.id == id)) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  # Validates that a blocker issue exists
  defp validate_blocker_exists(issues, id) do
    case Enum.find(issues, &(&1.id == id)) do
      nil -> {:error, :blocker_not_found}
      issue -> {:ok, issue}
    end
  end

  # Finds the index of an issue by ID
  defp find_issue_index(issues, id) do
    Enum.find_index(issues, &(&1.id == id))
  end

  # Persists all issues to JSONL file with advisory locking
  defp persist_issues(state) do
    # Ensure directory exists before attempting to acquire lock
    File.mkdir_p!(Path.dirname(state.file_path))

    # Ensure .gitattributes has merge=union for issues.jsonl
    ensure_gitattributes(state.file_path)

    lock_path = state.file_path <> ".lock"
    stale_threshold_ms = 30_000
    retry_interval_ms = 100
    timeout_ms = 10_000
    start_time = System.monotonic_time(:millisecond)

    with_lock(lock_path, stale_threshold_ms, retry_interval_ms, timeout_ms, start_time, fn ->
      write_issues(state)
    end)
  end

  # Acquires advisory lock with retry and stale detection
  defp with_lock(lock_path, stale_threshold, retry_interval, timeout, start_time, fun) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :lock_timeout}
    else
      case acquire_lock(lock_path, stale_threshold) do
        {:ok, lock_file} ->
          try do
            result = fun.()
            result
          after
            File.close(lock_file)
            File.rm(lock_path)
          end

        {:error, :locked} ->
          # Add jitter to retry interval
          jitter = :rand.uniform(retry_interval)
          Process.sleep(retry_interval + jitter)
          with_lock(lock_path, stale_threshold, retry_interval, timeout, start_time, fun)
      end
    end
  end

  # Attempts to acquire the advisory lock
  defp acquire_lock(lock_path, stale_threshold) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, file} ->
        # Write PID and timestamp as JSON
        lock_data = %{
          pid: System.pid(),
          timestamp: Issue.timestamp()
        }

        IO.write(file, Jason.encode!(lock_data))
        {:ok, file}

      {:error, :eexist} ->
        # Lock exists, check if stale
        case File.stat(lock_path) do
          {:ok, %File.Stat{mtime: mtime}} ->
            mtime_ms = :calendar.datetime_to_gregorian_seconds(mtime) * 1000
            now_ms = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) * 1000

            if now_ms - mtime_ms > stale_threshold do
              # Stale lock, delete and retry
              File.rm(lock_path)
              acquire_lock(lock_path, stale_threshold)
            else
              {:error, :locked}
            end

          {:error, :enoent} ->
            # Lock file disappeared, retry
            acquire_lock(lock_path, stale_threshold)

          _ ->
            {:error, :locked}
        end
    end
  end

  # Ensures .gitattributes contains merge=union for issues.jsonl
  defp ensure_gitattributes(_issues_file_path) do
    case Git.cmd(["rev-parse", "--show-toplevel"]) do
      {output, 0} ->
        repo_root = String.trim(output)
        update_gitattributes_file(repo_root)

      _error ->
        # Not in a git repo, skip gitattributes setup
        :ok
    end
  rescue
    _e ->
      # If anything goes wrong, log and continue (don't block issue creation)
      Logger.debug("Could not update .gitattributes for issues.jsonl merge strategy")
      :ok
  end

  # Updates or creates .gitattributes with the merge=union line
  defp update_gitattributes_file(repo_root) do
    gitattributes_path = Path.join(repo_root, ".gitattributes")
    required_line = ".deft/issues.jsonl merge=union"

    if File.exists?(gitattributes_path) do
      append_to_gitattributes_if_needed(gitattributes_path, required_line)
    else
      File.write!(gitattributes_path, required_line <> "\n")
    end
  end

  # Appends the required line to .gitattributes if not already present
  defp append_to_gitattributes_if_needed(gitattributes_path, required_line) do
    content = File.read!(gitattributes_path)

    unless String.contains?(content, required_line) do
      updated_content =
        if String.ends_with?(content, "\n") do
          content <> required_line <> "\n"
        else
          content <> "\n" <> required_line <> "\n"
        end

      File.write!(gitattributes_path, updated_content)
    end
  end

  # Writes issues to JSONL file atomically
  defp write_issues(state) do
    # Ensure directory exists
    File.mkdir_p!(Path.dirname(state.file_path))

    # Write to temp file
    temp_path = "#{state.file_path}.tmp.#{:erlang.unique_integer([:positive])}"

    try do
      lines =
        state.issues
        |> Enum.map(fn issue ->
          {:ok, json} = Issue.encode(issue)
          json <> "\n"
        end)

      File.write!(temp_path, lines)

      # Atomic rename
      File.rename!(temp_path, state.file_path)
      :ok
    rescue
      e ->
        # Clean up temp file on error
        File.rm(temp_path)
        {:error, e}
    end
  end
end
