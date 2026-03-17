# Filesystem (Deft.Store)

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Draft |
| Last Updated | 2026-03-16 |

## Changelog

### v0.1 (2026-03-16)
- Initial spec — `Deft.Store` GenServer wrapping DETS for tool result caching and curated job knowledge (diary). Replaces the data storage function of the Site Log.

## Overview

`Deft.Store` is a GenServer module that wraps DETS (Disk Erlang Term Storage). One module, two instance types with different configurations: **Cache** (tool result spilling) and **Diary** (curated job knowledge).

DETS does the heavy lifting — the GenServer layer adds access control, lifecycle management, and write policies on top.

**Scope:**
- `Deft.Store` GenServer (single module, multiple instances)
- Cache instance — tool result spilling with lazy writes and async rebuild
- Diary instance — Foreman-curated reference data with read access for Leads
- Tool result spilling protocol (threshold, summary, cache key)
- Directory layout under `~/.deft/`

**Out of scope:**
- Issue storage (separate spec, lives in project `.deft/`)
- Skill storage (separate spec)
- Tool definitions themselves (tools spec)
- Cross-job knowledge persistence (future — overlaps with cross-session memory)

**Dependencies:**
- [sessions.md](sessions.md) — session lifecycle, `~/.deft/` directory structure
- [orchestration.md](orchestration.md) — Foreman/Lead/Runner process architecture (will be updated to use Store instead of Site Log)

**Design principles:**
- **DETS is the database.** The GenServer is a policy layer, not a storage engine. No custom serialization, no WAL, no reinventing what DETS already provides.
- **One module, multiple instances.** Cache and Diary share the same GenServer code. Configuration (access control, write policy, cleanup behavior) differentiates them.
- **Runners stay lean.** Runners never interact with Cache or Diary. Their Lead inlines everything they need into their instructions.
- **Leads are isolated.** Cache entries are scoped per Lead. No cross-Lead reads unless the Foreman mediates. This prevents stale data leaking between parallel workstreams.

## Specification

### 1. Directory Layout

```
~/.deft/
  cache/<session_id>/          # Cache DETS files, one per Lead
    lead-<lead_id>.dets
  jobs/<job_id>/
    diary.dets                 # Diary DETS file, one per job
  sessions/                    # Session JSONL files (defined in sessions spec)
  config.yaml                  # User config (defined in sessions spec)
  skills/                      # Global user skills (defined in skills spec)
```

Cache files are ephemeral — deleted when the session ends. Diary files persist for the job lifetime.

### 2. Process Architecture

```
Deft.Store (GenServer — wraps DETS)
  - init/1:    opens DETS file, optionally kicks off async rebuild
  - write/3:   validates access control, writes to DETS (or write buffer)
  - read/2:    reads from DETS
  - delete/2:  removes entries by key
  - cleanup/2: removes entries by key pattern or age
  - terminate: closes DETS properly
```

Multiple instances run under supervision:

| Instance | Started | Lifecycle | Writer(s) | Reader(s) |
|----------|---------|-----------|-----------|-----------|
| Cache | Per Lead, per session | Session-scoped, ephemeral | Foreman, owning Lead (via tools) | Owning Lead, Foreman |
| Diary | Per job (if orchestrated) | Job lifetime | Foreman only | Leads (read-only) |

Each instance is registered with a unique name (e.g., `{:via, Registry, {Deft.Store, {:cache, session_id, lead_id}}}` or `{:via, Registry, {Deft.Store, {:diary, job_id}}}`).

### 3. Cache Instance

#### 3.1 Purpose

Tool result caching. When a tool result exceeds a token threshold, the tool writes a summary to the conversation and stores the full result in the cache. Agents can retrieve the full result later by cache key.

#### 3.2 Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `cache.token_threshold` | `4000` | Estimated token count above which tool results spill to cache |

#### 3.3 Write Policy — Lazy Writes

Cache writes are batched and asynchronous. The GenServer holds a write buffer and flushes to DETS periodically or when the buffer reaches a size threshold:

- Buffer flush interval: 5 seconds
- Buffer flush size: 50 entries
- Whichever comes first triggers a flush
- Reads check the write buffer first, then DETS (buffer acts as a write-through layer for reads)

Rationale: tool results arrive in bursts during active work. Batching avoids DETS write amplification on every individual tool call.

#### 3.4 Startup — Async Rebuild

On startup, the cache GenServer opens the DETS file and begins loading entries asynchronously. It does not block on full load — reads return `:miss` for entries that haven't loaded yet. This matters for crash recovery: if a Lead restarts mid-session, it comes back online immediately rather than waiting for a potentially large DETS file to load.

#### 3.5 Lead Isolation

Each Lead gets its own cache DETS file (`cache/<session_id>/lead-<lead_id>.dets`). Leads cannot read each other's cache entries directly. If a Lead needs data from another Lead's work, the Foreman mediates — reading from one cache and writing to the other, or inlining the data into instructions.

#### 3.6 Cleanup

Leads clean up their cache entries when they complete their deliverable. The Lead sends a `cleanup` call to its cache instance, which:
1. Flushes any buffered writes
2. Closes the DETS file
3. Deletes the DETS file from disk

On session end, any remaining cache files under `cache/<session_id>/` are deleted.

#### 3.7 Entry Schema

```
key     :: String.t()       # e.g., "grep-result-a1b2", "read-file-c3d4"
value   :: term()           # Full tool result (any Erlang term)
tool    :: atom()           # Tool that produced this result
created :: integer()        # System.monotonic_time/0 at write time
```

Keys are generated by the tool at spill time. Format: `<tool_name>-<random_hex>`.

### 4. Diary Instance

#### 4.1 Purpose

Curated job knowledge. The Foreman watches Lead messages and promotes valuable reference data to the diary. Leads can read the diary to access shared context — API contracts, schemas, architectural decisions, research findings.

The diary replaces the "data" function of the Site Log. Direct OTP process messages replace the Site Log's "coordination" function. The Site Log concept is removed from orchestration.

#### 4.2 Write Policy — Synchronous, Foreman Only

Diary writes are synchronous — the Foreman writes and the entry is immediately available to Leads. Write volume is low (the Foreman curates deliberately), so batching is unnecessary.

Access control: the GenServer validates that the calling process is the Foreman. Other callers receive `{:error, :unauthorized}`.

#### 4.3 What Goes in the Diary

The Foreman decides. Typical entries:
- API contracts discovered during research
- Database schemas relevant to the job
- Architectural decisions made during planning
- Research findings that multiple Leads need
- Corrections or clarifications from the user

The Foreman watches Lead messages (status updates, questions, results) and promotes data worth sharing. This is a judgment call by the Foreman's LLM, not a mechanical rule.

#### 4.4 Entry Schema

```
key       :: String.t()     # Descriptive key, e.g., "api-users-endpoint", "schema-orders"
value     :: term()          # The reference data
category  :: atom()          # :contract | :schema | :decision | :research | :correction
written_at :: String.t()    # ISO 8601 UTC
```

Keys are human-readable, chosen by the Foreman. Overwrites are allowed (same key replaces the previous entry).

#### 4.5 Lifecycle

- Created when a job starts with orchestration (Foreman + Leads)
- Not created for simple single-agent sessions
- Persists on disk for the job lifetime
- Not cleaned up automatically — job data may be useful for review

### 5. Tool Result Spilling

#### 5.1 Protocol

When a tool executes and the result exceeds `cache.token_threshold` (estimated tokens):

1. The tool writes the full result to the Lead's cache store
2. The tool generates a tool-specific summary of the result
3. The tool returns the summary + a cache reference in the context message

The summary is written by the tool itself — not by an LLM, and not by generic truncation. Each tool knows what's important about its output.

#### 5.2 Cache Reference Format

```
Full results: cache://<key>
```

This string appears at the end of the summary. The agent can later call a `cache_read` tool (or equivalent) with the key to retrieve the full result.

#### 5.3 Examples

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

#### 5.4 Token Estimation

Token count is estimated, not exact. Use byte length / 4 as a rough heuristic (one token per ~4 bytes for English text / code). Precision doesn't matter — the threshold is a soft boundary to keep context windows manageable, not a hard limit.

### 6. GenServer Implementation

#### 6.1 `start_link/1`

Options:
```elixir
%{
  type: :cache | :diary,
  path: String.t(),           # DETS file path
  name: term(),               # Process registration name
  access: %{
    writers: [pid() | atom()], # Processes allowed to write
    readers: [pid() | atom()]  # Processes allowed to read (nil = open)
  }
}
```

#### 6.2 `init/1`

1. Create parent directory if it doesn't exist
2. Open DETS file (`:dets.open_file/2`)
3. For cache instances: spawn async rebuild task, start flush timer
4. For diary instances: ready immediately

#### 6.3 Public API

```elixir
Deft.Store.write(server, key, value)     # => :ok | {:error, reason}
Deft.Store.read(server, key)             # => {:ok, value} | :miss
Deft.Store.delete(server, key)           # => :ok
Deft.Store.keys(server)                  # => [key]
Deft.Store.cleanup(server)               # => :ok (flush + close + delete file)
```

All calls validate the caller's PID against the access control list.

#### 6.4 `terminate/2`

1. Flush any buffered writes (cache)
2. Close DETS file (`:dets.close/1`)

This ensures clean shutdown even on crashes — the supervisor calls `terminate` before restarting.

## Notes

### Design decisions

- **DETS over ETS.** Cache data can be large (full file contents, grep results). ETS is memory-only — a crash loses everything. DETS persists to disk, enabling crash recovery without re-running tools. The async rebuild on startup means the recovery cost is amortized.
- **DETS over JSONL.** The Site Log and issues use JSONL because git-diffability matters. Cache and diary data is ephemeral/operational — there's no reason to make it human-readable or git-mergeable. DETS gives us O(1) key lookup, atomic writes, and Erlang term storage for free.
- **Lazy writes for cache, sync writes for diary.** Cache sees burst writes from parallel tool execution. Diary sees occasional writes from the Foreman. The write policies match the access patterns.
- **Per-Lead cache isolation.** The alternative was a shared cache with Lead-scoped keys. Separate DETS files are simpler — no key-prefix conventions, cleanup is just deleting a file, and there's zero risk of cross-Lead data leakage.
- **Tool-authored summaries.** LLM-generated summaries would require an extra API call per spill (expensive, slow). Generic truncation loses important context. Tools know their own output structure — a grep tool knows to show match count and top results, a file read tool knows to show the first N lines. This is cheap, fast, and domain-appropriate.
- **Runners don't get store access.** Runners are short-lived, focused executors. Adding store access would complicate their interface for minimal benefit. The Lead already curates what each Runner needs and inlines it into instructions.
- **No cross-job diary persistence.** Diary data is job-scoped. Cross-job knowledge (e.g., "this codebase uses Phoenix 1.7 conventions") is a different problem that overlaps with cross-session memory. Deferring to a future spec rather than overloading the diary concept.
- **Site Log removal.** The Site Log served two functions: coordination (agent messages) and data (shared knowledge). OTP message passing replaces coordination. The diary replaces data. There's no remaining need for the Site Log abstraction.

## References

- [sessions.md](sessions.md) — session lifecycle, `~/.deft/` directory
- [orchestration.md](orchestration.md) — Foreman/Lead/Runner architecture
- [Erlang DETS documentation](https://www.erlang.org/doc/man/dets.html) — storage engine
