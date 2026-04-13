# Runners

| | |
|--------|----------------------------------------------|
| Version | 0.18 |
| Status | Ready |
| Last Updated | 2026-04-13 |

## Changelog

### v0.18 (2026-04-13)
- Audit demoted to Ready: Foreman.Coordinator has no spawn path for `:merge_resolution` Runners (§2), and `job.runner_timeout` (§4) is not threaded through to `collect_stream_events/3` — the timeout is hardcoded in source.

### v0.17 (2026-04-10)
- Extracted from orchestration.md §6 into standalone sub-spec

## Overview

A Runner is a short-lived inline agent loop that executes a single task. Runners are spawned as `Task.Supervisor.async_nolink` tasks — either by the Foreman.Coordinator (research, verification) or by Lead.Coordinators (implementation, testing, review, merge resolution). No gen_statem, no OM, no persistent state.

**Scope:**
- Runner types and tool sets
- Inline loop behavior
- Context from Lead/Foreman

**Dependencies:**
- [lead.md](lead.md) — Lead.Coordinator spawns most Runners
- [coordinator.md](coordinator.md) — Foreman.Coordinator spawns research/verification Runners
- [../rate-limiter.md](../rate-limiter.md) — all LLM calls flow through RateLimiter

## Specification

### 1. Inline Loop

Runners run a simple function: build minimal context → call LLM (through RateLimiter) → parse tool calls → execute tools inline with try/catch → loop or return results via Task return value. No gen_statem, no OM.

Runners do NOT message the Foreman.Coordinator directly. The Lead.Coordinator is the intermediary. Research and verification Runners spawned by the Foreman.Coordinator return results via Task return value.

### 2. Tool Sets

| Runner type | Tools | Spawned by |
|-------------|-------|-----------|
| Research | read, grep, find, ls (read-only) | Foreman.Coordinator |
| Implementation | read, write, edit, bash, grep, find, ls | Lead.Coordinator |
| Testing | read, bash, grep, find, ls (no write/edit) | Lead.Coordinator |
| Review | read, grep, find, ls (read-only) | Lead.Coordinator |
| Merge resolution | read, write, edit, grep | Foreman.Coordinator |
| Verification | read, bash, grep, find, ls (no write/edit) | Foreman.Coordinator |

### 3. Context from Lead

The Lead.Coordinator provides each Runner with task instructions, curated context, and the worktree path. Runners do NOT read the site log directly.

### 4. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.runner_model` | `"claude-sonnet-4"` | Model for Runners |
| `job.research_runner_model` | `"claude-sonnet-4"` | Model for research Runners |
| `job.research_timeout` | `120_000` | Timeout for research Runners (ms) |
| `job.runner_timeout` | `300_000` | Timeout for implementation Runners (ms) |

## References

- [lead.md](lead.md) — Lead.Coordinator
- [coordinator.md](coordinator.md) — Foreman.Coordinator
- [../rate-limiter.md](../rate-limiter.md) — rate limiter
