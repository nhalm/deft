# Logging

| | |
|--------|----------------------------------------------|
| Version | 0.6 |
| Status | Implemented |
| Last Updated | 2026-03-30 |

## Changelog

### v0.6 (2026-03-30)
- Remove "Session saved" from Infrastructure logging requirements — Session persistence happens continuously via append with no discrete "save" event worth logging at info level; "Session resumed" already covers the meaningful lifecycle event

### v0.5 (2026-03-30)
- Silence keystroke noise: remove app-level keydown logging, disable Phoenix built-in callback logging, keep only meaningful UI events at debug level
- Fix "only callers log" violation in Session Store: move "Session loaded" log out of `Store.load/2` and into callers that warrant it (e.g., `resume`), so `list_sessions` doesn't spam on startup

### v0.4 (2026-03-27)
- Remove status code from "Provider stream complete" requirement — successful stream completion inherently means 200; non-200 responses are logged as provider failures

### v0.3 (2026-03-27)
- Add logging ownership principle: only callers log, low-level functions return results
- Remove Git and Provider from logging layers — they are low-level and do not log

### v0.2 (2026-03-26)
- Move "Job abort" from Error to Info level (abort is user-initiated, not an error condition)
- Add "Job abort cleanup failures" to Error level (for when cleanup fails during abort)

### v0.1 (2026-03-26)
- Initial spec: log level configuration, per-layer logging requirements, message conventions

## Overview

Deft uses Elixir's built-in Logger for operational visibility across all layers. Log levels are configurable via environment variable. Every module that performs meaningful work logs what it's doing at an appropriate level.

**Scope:**
- Log level configuration
- What each application layer logs and at what level
- Log message conventions and correlation

**Out of scope:**
- Structured/JSON logging or external log backends (future)
- Log aggregation or shipping
- Metrics or telemetry dashboards

**Dependencies:**
- [harness](harness.md) — Agent gen_statem
- [providers](providers.md) — Provider modules
- [web-ui](web-ui.md) — Phoenix LiveView interface
- [orchestration](orchestration.md) — Foreman/Lead/Runner hierarchy

**Design principles:**
- **Only callers log.** Low-level functions return deterministic results (`{:ok, _}` / `{:error, _}`). They do not log. The caller has the context to decide whether a failure is expected, recoverable, or fatal — and logs accordingly. This applies to git operations, HTTP calls, file I/O, parsing, and any utility function.
- `:info` tells you what happened (prompt received, LLM called, tools ran, turn complete)
- `:debug` tells you the details (individual events, broadcasts, state transitions)
- High-frequency UI events (keypresses) are not logged at any level — they generate too much noise even at `:debug` and have no diagnostic value
- Never log message content or tool output — may contain secrets. Log lengths, counts, types, and durations.

## Specification

### 1. Log Level Configuration

The `LOG_LEVEL` environment variable controls the global log level. Valid values: `debug`, `info`, `warning`, `error`. Default: `info`.

The test environment defaults to `:warning`.

Per-module overrides use Elixir's built-in `Logger` module-level configuration — no custom abstraction.

### 2. Log Message Format

All log messages include a bracketed prefix identifying the layer and context:

- `[Agent:<id>]` — agent lifecycle (id is first 8 chars of session ID)
- `[Provider:<id>]` — LLM API communication
- `[Chat:<id>]` — web UI interaction
- `[Foreman:<id>]` — job orchestration (id is job ID prefix)
- `[Lead:<id>]` — sub-task execution
- `[Git:<id>]` — git operations
- `[OM:<id>]` — observational memory
- `[Tools:<id>]` — tool execution
- `[Store]` — filesystem/cache operations
- `[Skills]` — skill registry and loading
- `[Issues]` — issue tracker operations
- `[Session]` — session persistence

Example: `[info] [Agent:a1b2c3d4] Prompt received, 342 chars`

### 3. Phoenix Layer

Phoenix's built-in LiveView callback logging is disabled (`log: false` in the `live_view` macro). App-level logging in LiveView modules provides better context (prefixed, selective), making Phoenix's generic `HANDLE EVENT` lines redundant.

### 4. Agent Layer

The agent logs its message lifecycle:

**Info level:**
- Prompt received (input length)
- Prompt queued when agent is busy (current state, queue depth)
- Provider stream started (provider module, model name)
- Provider stream complete (duration)
- Tool execution started (tool count, tool names)
- Tool execution complete (duration, success/failure count)
- Turn complete (total turn duration)
- Abort requested (current state)

**Debug level:**
- Individual SSE events received (event type)
- Event broadcasts (event type)
- State transitions (old → new state)
- Queued prompt processing (queue depth)

**Warning level:**
- Stream errors

**Error level:**
- Provider failures (status code, error reason — logged by agent, not provider module)
- Tool crashes (tool name, reason)

### 5. Orchestration Layer

**Info level:**
- Job started (job ID, description)
- Phase transitions (planning → researching → executing, etc.)
- Lead spawned/completed (lead ID, task summary)
- Cost checkpoints (accumulated cost)
- Job complete (duration, total cost)
- Job abort (user-initiated)

**Debug level:**
- Lead message dispatch (message type)
- Runner task assignment
- Branch operations (create, merge, cleanup)

**Warning level:**
- Cost threshold approaching
- Merge conflicts detected
- Lead verification failures

**Error level:**
- Lead crashes
- Git operation failures (logged by the orchestration caller, not by git functions)
- Job abort cleanup failures

### 7. Observational Memory Layer

**Info level:**
- Observer triggered (observation count)
- Reflector triggered (compression ratio)
- Snapshot persisted

**Debug level:**
- Individual observation extraction
- Reflection LLM calls
- Section updates

**Warning level:**
- Observer/Reflector task failures

### 8. Chat Layer

**Info level:**
- User submits message (input length)
- Session connected/disconnected

**Debug level:**
- Agent events received for rendering (event type)
- Discrete UI events: toggle_thinking, toggle_tool (event name only)

**Not logged (any level):**
- Keydown events — high-frequency, no diagnostic value

### 9. Infrastructure Layer

Covers Store, Skills, Issues, Session modules.

**Info level:**
- Session resumed (session ID, entry count) — logged by `resume`, not by `load`
- Issue created/updated
- Skill registered

`Store.load/2` is a low-level function called by multiple callers (resume, list_sessions, extract_metadata). Per the "only callers log" principle, `load` does not log. Callers that represent meaningful user-facing actions (like `resume`) log at their own level.

**Debug level:**
- Cache hits/misses
- DETS operations
- Skill file parsing

**Warning level:**
- Persistence failures (with retry)
- Invalid data encountered (malformed issues, unparseable skills)

**Error level:**
- Unrecoverable persistence failures
- Data corruption detected
