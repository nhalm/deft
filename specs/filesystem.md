# Filesystem (Deft.Store)

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Implemented |
| Last Updated | 2026-03-18 |

## Changelog

### v0.3 (2026-03-18)
- Fixed directory layout: use `git rev-parse --git-common-dir` + `Path.dirname/1` instead of `--show-toplevel` for git worktree canonical root. `--show-toplevel` returns the worktree root, not the main repo root, breaking project directory resolution for Leads.

### v0.2 (2026-03-16)
- Renamed "Diary" to "Site Log" throughout (instance type, DETS filename, section headers, references).
- ETS tables are now unnamed (no `:named_table`). Use tid (table reference integer) for reads. Eliminates naming collisions across multiple instances.
- Added `try/rescue ArgumentError -> :miss` in `read/2` for graceful handling of table-owner crash.
- Added `:dets.sync/1` after every site log write. Cache writes do not sync (ephemeral data, loss on crash is acceptable).
- Added DETS corruption recovery: fallback to new empty file on `dets.open_file/2` error. Warning logged for site log corruption; cache corruption is silent.
- Specified async load task lifecycle: `Task.async` linked to GenServer, `handle_info` for completion/failure, `Task.shutdown(task, :brutal_kill)` on cleanup.
- Replaced PID-based access control with Registry-resolved named references for site log writes. Survives Foreman restarts.
- Added `closed` flag to GenServer state to prevent double-flush in cleanup/terminate.
- Added `cache_read` tool definition (section 6.3).
- Added system prompt integration for cache spilling (section 6.4).
- Replaced single `cache.token_threshold` with per-tool threshold configuration.
- Added `critical_finding` to site log promotion rules.
- Updated directory layout: symlink resolution, git worktree canonical root, monorepo note.

### v0.1 (2026-03-16)
- Initial spec — `Deft.Store` GenServer wrapping ETS + DETS for tool result caching and curated job knowledge (site log). Replaces the data storage function of the Site Log. Project-scoped directory layout under `~/.deft/projects/`.

## Overview

`Deft.Store` is a GenServer module that wraps ETS (fast in-memory reads) backed by DETS (disk persistence). One module, multiple instances with different configurations: **Cache** (tool result spilling) and **Site Log** (curated job knowledge).

ETS handles reads — concurrent, no process bottleneck. DETS handles persistence — async writes, crash recovery. The GenServer manages access control, lifecycle, and write policies.

**Scope:**
- `Deft.Store` GenServer (single module, multiple instances)
- Cache instance — tool result spilling, session-scoped, Lead-isolated
- Site Log instance — Foreman-curated reference data, job-scoped, programmatic promotion
- Tool result spilling protocol (threshold, summary, cache key)
- Directory layout under `~/.deft/projects/`

**Out of scope:**
- Issue storage (separate spec, lives in project `.deft/`)
- Skill/command storage (separate spec)
- Tool definitions themselves (tools spec)
- Cross-job knowledge persistence (future — overlaps with cross-session memory)

**Dependencies:**
- [sessions.md](sessions.md) — session lifecycle
- [orchestration.md](orchestration.md) — Foreman/Lead/Runner process architecture, OTP coordination protocol

**Design principles:**
- **ETS for reads, DETS for durability.** Fast concurrent reads from ETS. DETS is the write-behind persistence layer. The GenServer manages the sync.
- **One module, multiple instances.** Cache and Site Log share the same GenServer code. Configuration (access control, write policy, cleanup behavior) differentiates them.
- **Runners stay lean.** Runners never interact with Cache or the Site Log. Their Lead inlines everything they need into their instructions.
- **Leads are isolated.** Cache entries are scoped per Lead. No cross-Lead reads unless the Foreman mediates.

## Specification

### 1. Directory Layout

```
~/.deft/
  config.yaml                            # User config (defined in sessions spec)
  skills/                                # Global user skills (defined in skills spec)
  commands/                              # Global user commands (defined in skills spec)
  projects/
    <path-encoded-repo>/                 # e.g., -Users-nickhalm-personal-myapp
      sessions/
        <session_id>.jsonl               # Session conversation logs
      cache/
        <session_id>/
          lead-<lead_id>.dets            # Per-Lead cache (ETS backed by DETS)
      jobs/
        <job_id>/
          sitelog.dets                    # Foreman's curated knowledge
```

Project directories use path-encoded names (replace `/` with `-`, strip leading `-`). A project maps to a git repository root.

Resolve the working directory to a real path (no symlinks) via symlink resolution (e.g. `File.realpath/1` or `:file.read_link_all/1`) before encoding. For git worktrees, use `git rev-parse --git-common-dir` + `Path.dirname/1` to find the canonical repo root (`--show-toplevel` returns the worktree root, not the main repo root).

Monorepos share a single project directory — the site log is repo-scoped, not subdirectory-scoped.

Cache files are ephemeral — deleted when the session ends. Site log files persist for the job lifetime.

### 2. Process Architecture

```
Deft.Store (GenServer — owns ETS table, backed by DETS file)
  - init/1:    opens DETS, creates ETS, loads DETS → ETS async
  - write/3:   validates access, writes to ETS immediately, queues DETS write
  - read/2:    reads from ETS directly (no GenServer call needed)
  - delete/2:  removes from ETS + DETS
  - cleanup/1: flushes pending writes, closes DETS, deletes file
  - terminate: flushes + closes DETS (short-circuits if already cleaned up)
```

Multiple instances run under supervision:

| Instance | Started | Lifecycle | Writer(s) | Reader(s) |
|----------|---------|-----------|-----------|-----------|
| Cache | Per Lead, per session | Session-scoped, ephemeral | Owning Lead (via tools) | Owning Lead, Foreman |
| Site Log | Per job (if orchestrated) | Job lifetime | Foreman only | Leads (read-only) |

Each instance is registered via `Registry`: `{:via, Registry, {Deft.Store, {:cache, session_id, lead_id}}}` or `{:via, Registry, {Deft.Store, {:sitelog, job_id}}}`.

### 3. ETS + DETS Interaction

The ETS table is the authority for reads. DETS is the write-behind persistence layer.

**Write path:**
1. Write to ETS immediately (available for reads instantly)
2. Queue the write for DETS flush
3. Flush to DETS periodically or on buffer threshold

**Read path:**
1. Read from ETS directly — this is a function call using the tid (table reference integer), not a GenServer call. No process bottleneck.
2. If the ETS table is still loading (async startup), return `:miss` for entries not yet loaded.
3. Reads wrap ETS access in `try/rescue ArgumentError -> :expired` to handle the case where the table-owning process has crashed and the table no longer exists. Returns `:expired` (not `:miss`) to distinguish from "key not found".

**Startup:**
1. Open DETS file. If `:dets.open_file/2` returns an error, fall back to creating a new empty DETS file. Log a warning for site log corruption. Cache corruption is silent (ephemeral data).
2. Create ETS table (`:set`, `:protected`). Tables are unnamed — use the tid (table reference integer) for all subsequent access. This eliminates naming collisions across multiple instances.
3. Start an async load task with `Task.async` (linked to the GenServer) to load DETS entries into ETS.
4. GenServer is ready immediately — reads return `:miss` for not-yet-loaded entries.

The GenServer handles the load task lifecycle:
- `handle_info({ref, :loaded}, state)` — task completed successfully. Demonitor and discard the DOWN message.
- `handle_info({:DOWN, ref, :process, pid, reason}, state)` — task failed. Log a warning. ETS stays partially populated; reads return `:miss` for not-yet-loaded entries.

**Shutdown:**
1. If an async load task is still running, `Task.shutdown(task, :brutal_kill)`.
2. Flush any buffered writes to DETS.
3. Close DETS file via `:dets.close/1`.

### 4. Cache Instance

#### 4.1 Purpose

Tool result caching. When a tool result exceeds a token threshold, the tool writes a summary to the conversation and stores the full result in the cache. Agents can retrieve the full result later by cache key.

#### 4.2 Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `cache.token_threshold` | `10000` | Default estimated token count above which tool results spill to cache (for tools not listed below) |
| `cache.token_threshold.read` | `20000` | File reads — partial context causes bugs, so a higher threshold avoids premature spilling |
| `cache.token_threshold.grep` | `8000` | Match lists — summaries work well for grep output |
| `cache.token_threshold.ls` | `4000` | Directory trees — structural summaries are fine |
| `cache.token_threshold.find` | `4000` | File listings — structural summaries are fine |

These defaults are provisional. Actual values should be determined by threshold calibration evals (see [evals/spilling.md](evals/spilling.md)).

#### 4.3 Write Policy — Lazy/Batched

Cache writes are batched and asynchronous to DETS. The GenServer holds a write buffer and flushes periodically:

- Buffer flush interval: 5 seconds
- Buffer flush size: 50 entries
- Whichever comes first triggers a flush
- ETS is updated immediately on every write (reads always see latest data)
- No `:dets.sync/1` after flush — cache data is ephemeral, loss on crash is acceptable

Rationale: tool results arrive in bursts during active work. Batching avoids DETS write amplification. ETS ensures reads are never stale despite lazy DETS writes.

#### 4.4 Lead Isolation

Each Lead gets its own cache instance (separate ETS table + DETS file). Leads cannot read each other's cache entries directly. If a Lead needs data from another Lead's work, the Foreman mediates.

#### 4.5 Cleanup

Leads clean up their cache on completion:
1. Set the `closed` flag to `true` in GenServer state.
2. If an async load task is still running, `Task.shutdown(task, :brutal_kill)`.
3. Flush buffered writes to DETS.
4. Delete ETS table.
5. Close and delete DETS file.

`terminate/2` checks the `closed` flag and short-circuits if already cleaned up, preventing double-flush.

On session end, any remaining cache files under `cache/<session_id>/` are deleted.

#### 4.6 Entry Schema

```
key     :: String.t()       # e.g., "grep-a1b2", "read-c3d4"
value   :: term()           # Full tool result (any Erlang term)
tool    :: atom()           # Tool that produced this result
created :: integer()        # System.monotonic_time/0
```

Keys are generated by the tool: `<tool_name>-<random_hex>`.

### 5. Site Log Instance

#### 5.1 Purpose

Curated job knowledge. The Foreman promotes valuable reference data to the site log. Leads read the site log to access shared context — API contracts, schemas, architectural decisions, research findings.

The site log replaces the "data" function of the previous Site Log file. Direct OTP process messages replace the "coordination" function.

#### 5.2 Write Policy — Synchronous, Foreman Only

Site log writes go to ETS and DETS synchronously. After every site log write, `:dets.sync/1` is called to ensure durability. Write volume is low (the Foreman curates deliberately), so the sync cost is acceptable.

Access control: the site log instance stores the Foreman's registered name (e.g., `{:via, Registry, {Deft.Job, {:foreman, job_id}}}`), not its PID. On write, the GenServer resolves the registered name to a PID via `Registry.lookup/2` and compares with the calling process (`self()`). This survives Foreman process restarts because the restarted Foreman re-registers under the same name. Other callers receive `{:error, :unauthorized}`.

#### 5.3 Programmatic Site Log Promotion

The site log manager runs inside the Foreman process. It uses pattern matching on Lead messages to decide what gets promoted — no LLM call needed:

| Message type | Promotion rule |
|-------------|----------------|
| `contract` | Always promote — API shapes, interface definitions |
| `decision` | Always promote — architectural choices with rationale |
| `critical_finding` | Always promote — the Lead's LLM judges importance and tags critical findings for auto-promotion |
| `finding` (research) | Promote if tagged as `shared` by the Lead when forwarding to the Foreman (the Lead decides whether a Runner's finding is worth sharing) |
| `correction` (from user) | Always promote |
| `status` | Never — ephemeral progress updates |
| `blocker` | Never — coordination, not knowledge |

The Foreman can also write arbitrary site log entries via its own judgment (LLM-driven), but the programmatic rules handle the common cases without an LLM call.

#### 5.4 Entry Schema

```
key        :: String.t()     # Descriptive key, e.g., "api-users-endpoint", "schema-orders"
value      :: term()         # The reference data
category   :: atom()         # :contract | :schema | :decision | :research | :correction | :critical_finding
written_at :: String.t()     # ISO 8601 UTC
```

Keys are human-readable, chosen by the Foreman or the promotion rules. Overwrites are allowed (same key replaces the previous entry).

#### 5.5 Lead Read Access

Leads obtain the site log's ETS tid via `Deft.Store.tid(server)` — a `GenServer.call` that returns the tid from the GenServer's state. Once a Lead has the tid, it reads directly from ETS (no further GenServer calls needed). The Foreman passes the site log's registered name to each Lead at startup; the Lead resolves it and caches the tid locally.

Since the ETS table is `:protected` (owner-write, other-read), Leads can read but cannot accidentally write. Only the Foreman (the GenServer owner) can write via the `write/4` API.

#### 5.6 Lifecycle

- Created when a job starts with orchestration (Foreman + Leads)
- Not created for simple single-agent sessions
- Persists on disk for the job lifetime
- Not cleaned up automatically — job data may be useful for review

### 6. Tool Result Spilling

#### 6.1 Protocol

When a tool executes and the result exceeds the tool's `cache.token_threshold` (estimated as byte_size / 4):

1. The tool writes the full result to the Lead's cache store
2. The tool generates a tool-specific summary
3. The tool returns the summary + a cache reference in the context message

Each tool writes its own summary — not LLM-generated, not generic truncation. The tool knows what's important about its output.

#### 6.2 Cache Reference Format

```
Full results: cache://<key>
```

The agent can later read the full result using the cache key via the `cache_read` tool.

#### 6.3 Cache Retrieval Tool

The `cache_read` tool allows agents to retrieve full cached results or filtered subsets.

**Tool definition:**

| Field | Description |
|-------|-------------|
| Name | `cache_read` |
| Parameters | `key` (required, string) — the cache key from the `cache://<key>` reference |
| | `lines` (optional, string) — line range for file reads, e.g., `"740-760"` |
| | `filter` (optional, string) — grep-style pattern to filter cached results |
| Returns | Full cached result, or filtered subset if `lines` or `filter` is provided |

**Error cases:**

| Error | Meaning |
|-------|---------|
| `:miss` | Key not found in cache |
| `:expired` | Cache has been cleaned up (session or Lead ended) |

The `cache_read` tool is only included in the agent's tool list when the session has active cache entries. If no cache entries exist, the tool is omitted to avoid confusing the agent.

#### 6.4 System Prompt Integration

When cache spilling is active (the session has cached entries), the system prompt includes the following instruction:

> When a tool result contains `Full results: cache://<key>`, the full output is stored in cache. Use the `cache_read` tool to retrieve it when you need details not in the summary. You can filter results: `cache_read(key, filter: 'pattern')` or request specific line ranges: `cache_read(key, lines: '740-760')`.

This instruction is removed from the system prompt when no cache entries are active.

#### 6.5 Examples

**Grep tool** — 47 matches across 12 files:
```
47 matches across 12 files. Top 10 shown:

  lib/accounts/user.ex:14: defstruct [:id, :email, :name]
  lib/accounts/user.ex:28: def changeset(user, attrs) do
  ...

Full results: cache://grep-a1b2c3
```

**File read** — large file:
```
lib/router.ex (847 lines). First 100 lines shown:

  defmodule MyApp.Router do
    use Plug.Router
    ...

Full results: cache://read-d4e5f6
```

**Directory listing** — deep tree:
```
src/ — 234 files across 18 directories. Top-level structure:

  src/accounts/    (12 files)
  src/orders/      (23 files)
  src/web/         (45 files)
  ...

Full results: cache://ls-g7h8i9
```

#### 6.6 Token Estimation

Byte length / 4 as a rough heuristic. Precision doesn't matter — the threshold is a soft boundary to keep context windows manageable, not a hard limit.

### 7. GenServer API

```elixir
# Write (goes through GenServer for access control + DETS queue)
Deft.Store.write(server, key, value, metadata)  # => :ok | {:error, reason}

# Read (direct ETS lookup by tid, no GenServer call)
Deft.Store.read(tid, key)                       # => {:ok, entry} | :miss | :expired

# Delete (goes through GenServer)
Deft.Store.delete(server, key)                  # => :ok

# List keys (direct ETS lookup by tid)
Deft.Store.keys(tid)                            # => [key]

# Cleanup (flush + close + delete)
Deft.Store.cleanup(server)                      # => :ok
```

Read and key listing go directly to ETS via the tid (table reference integer) — no process message needed. Write, delete, and cleanup go through the GenServer for serialization and access control.

The `read/2` implementation wraps ETS access:

```elixir
def read(tid, key) do
  try do
    case :ets.lookup(tid, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  rescue
    ArgumentError -> :expired
  end
end
```

## Notes

### Design decisions

- **ETS + DETS over DETS alone.** DETS reads are slower than ETS (disk I/O). ETS gives us concurrent reads without going through a process. DETS is just the persistence layer — the write-behind cache for crash recovery.
- **Unnamed ETS tables with tid.** Named tables create a global namespace that risks collisions when multiple instances coexist. Using the tid (table reference integer) scopes access to the owning process's knowledge of the reference.
- **Binary storage is fine.** DETS files are not human-readable. That's acceptable — cache data is ephemeral runtime state, site log data is operational. Nobody needs to `cat` these files. Tools interact through the GenServer API, not the filesystem.
- **Lazy writes for cache, sync writes for site log.** Cache sees burst writes from parallel tool execution. The site log sees occasional writes from the Foreman. The write policies match the access patterns. Site log writes call `:dets.sync/1` for durability; cache writes skip sync because data loss on crash is acceptable for ephemeral data.
- **Per-Lead cache isolation.** Separate ETS tables + DETS files per Lead. No key-prefix conventions, cleanup is just deleting a file, zero risk of cross-Lead data leakage.
- **Registry-based access control for site log.** Storing the Foreman's registered name instead of its PID ensures write authorization survives process restarts. The restarted Foreman re-registers under the same name, so the site log instance can resolve it to the new PID.
- **Programmatic site log promotion.** Pattern matching on message types is cheap and predictable. The Foreman can still write arbitrary entries when its LLM judgment says to, but the common cases (contracts, decisions, corrections, critical findings) are handled without an LLM call.
- **Tool-authored summaries.** LLM-generated summaries would require an extra API call per spill (expensive, slow). Generic truncation loses important context. Tools know their own output structure — cheap, fast, domain-appropriate.
- **Runners don't get store access.** Runners are short-lived, focused executors. Adding store access would complicate their interface for minimal benefit.
- **Per-tool spill thresholds.** Different tools produce output with different information density. File reads lose critical context when truncated (high threshold), while directory listings summarize well (low threshold).
- **Closed flag for cleanup idempotency.** The `closed` boolean in GenServer state prevents `terminate/2` from double-flushing when `cleanup/1` has already run. Without this, a supervised shutdown after explicit cleanup would attempt to flush and close DETS twice.

## References

- [sessions.md](sessions.md) — session lifecycle
- [orchestration.md](orchestration.md) — Foreman/Lead/Runner architecture
- [Erlang ETS documentation](https://www.erlang.org/doc/man/ets.html) — in-memory storage
- [Erlang DETS documentation](https://www.erlang.org/doc/man/dets.html) — disk persistence
