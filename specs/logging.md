# Logging

| | |
|--------|----------------------------------------------|
| Version | 0.2 |
| Status | Implemented |
| Last Updated | 2026-03-26 |

## Changelog

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
- `:info` tells you what happened (prompt received, LLM called, tools ran, turn complete)
- `:debug` tells you the details (individual events, broadcasts, state transitions)
- High-frequency UI events (keypresses) stay at `:debug` to avoid noise
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

LiveView callbacks (mount, handle_event, handle_info) log at `:debug` level. This keeps keypress and high-frequency UI events out of normal output while making them available when needed.

### 4. Agent Layer

The agent logs its message lifecycle:

**Info level:**
- Prompt received (input length)
- Prompt queued when agent is busy (current state, queue depth)
- Provider stream started (provider module)
- Stream complete (duration)
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
- Unrecoverable provider failures
- Tool crashes (tool name, reason)

### 5. Provider Layer

**Info level:**
- API request started (model name, message count, tool count)
- API request complete (status code, response time)

**Debug level:**
- SSE chunk received (size in bytes)
- SSE event parsed (event type)

**Error level:**
- Non-2xx API responses (status code, truncated error body)
- Connection failures (error reason)

### 6. Orchestration Layer

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
- Git operation failures
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

### 9. Infrastructure Layer

Covers Store, Skills, Issues, Session modules.

**Info level:**
- Session loaded/saved
- Issue created/updated
- Skill registered

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
