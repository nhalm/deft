# Session Persistence

| | |
|--------|----------------------------------------------|
| Version | 0.8 |
| Status | Implemented |
| Last Updated | 2026-04-10 |

## Changelog

### v0.8 (2026-04-10)
- Extracted from sessions.md §1 into standalone sub-spec
- Added `checkpoint` entry type for branching support (see [branching.md](branching.md))

## Overview

Session persistence defines how Deft stores and restores conversation state. Sessions are append-only JSONL files where each line represents one event in the session timeline. This format supports both user sessions (conversations) and agent sessions (internal LLM state for orchestrated sub-agents).

**Scope:**
- JSONL storage format and entry types
- Storage paths for user sessions and agent sessions
- Session resume (reconstruct state from JSONL)
- Session listing

**Out of scope:**
- Context assembly and compaction (see [context.md](context.md))
- Session branching mechanics (see [branching.md](branching.md))

**Dependencies:**
- [../harness.md](../harness.md) — message format
- [../filesystem.md](../filesystem.md) — project-scoped directory layout
- [../observational-memory.md](../observational-memory.md) — observation entry format

## Specification

### 1. Storage Format

Sessions are stored as JSONL files. Each line is a JSON object representing one event in the session timeline.

There are two kinds of sessions, both using the same JSONL format:

**User sessions** — conversations between the user and Deft. These are the primary sessions.
- Storage: `~/.deft/projects/<path-encoded-repo>/sessions/<session_id>.jsonl`
- Listed in the web UI session picker. Resumable by the user.

**Agent sessions** — internal LLM conversation history for orchestrated sub-agents (ForemanAgent, LeadAgents). These are not user-facing.
- Storage: `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/foreman_session.jsonl` and `lead_<id>_session.jsonl`
- Not listed in the session picker. Not directly resumable — the orchestrator starts fresh agents on job resume (see [../orchestration.md](../orchestration.md)).
- Same entry types, same format. The only difference is storage path and lifecycle.

Sessions are scoped per-project. The project is identified by the git repository root (resolved to a real path, no symlinks). The path is encoded by replacing `/` with `-` (e.g., `/Users/nick/myapp` -> `-Users-nick-myapp`). See [../filesystem.md](../filesystem.md) for the full `~/.deft/projects/` layout.

### 2. Entry Types

| Type | Description |
|------|-------------|
| `session_start` | Session metadata: ID, created_at, working_dir, model, config snapshot |
| `message` | A conversation message: role, content blocks, tool_calls, thinking, timestamp |
| `tool_result` | Tool execution result: tool_call_id, name, result, duration_ms, is_error |
| `model_change` | Model was changed mid-session |
| `observation` | OM state snapshot (see [../observational-memory.md](../observational-memory.md)) |
| `compaction` | Context was compacted: summary text, messages removed |
| `cost` | Cost checkpoint: cumulative session cost at this point |
| `checkpoint` | Named snapshot: label, entry_index (line number in JSONL), git_ref (commit SHA at this point). Created by user via `/checkpoint` command or automatically before branching. See [branching.md](branching.md). |

### 3. Session Resume

When resuming a session:
1. Read the JSONL file and reconstruct conversation state
2. Rebuild the message list from `message` and `tool_result` entries
3. Restore OM state from the latest `observation` entry
4. Display a summary of the previous conversation to the user

### 4. Session Listing

Sessions are listed by most-recent-first. Each session shows: ID (short), working directory, last message timestamp, message count, and first line of the last user prompt.

## References

- [../harness.md](../harness.md) — message format
- [../filesystem.md](../filesystem.md) — directory layout
- [../observational-memory.md](../observational-memory.md) — observation entries
- [branching.md](branching.md) — session forking from checkpoints
