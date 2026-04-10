# Session Context

| | |
|--------|----------------------------------------------|
| Version | 0.8 |
| Status | Implemented |
| Last Updated | 2026-04-10 |

## Changelog

### v0.8 (2026-04-10)
- Extracted from sessions.md §3-4 into standalone sub-spec

## Overview

Session context management defines how Deft assembles the message list for each LLM turn, tracks token usage and cost, and compacts context when approaching the context window limit.

**Scope:**
- System prompt assembly
- Message list construction per turn
- Token tracking and context window management
- Compaction (context compression fallback)
- Cost tracking

**Out of scope:**
- JSONL persistence format (see [persistence.md](persistence.md))
- Observational memory internals (see [../observational-memory.md](../observational-memory.md))

**Dependencies:**
- [../harness.md](../harness.md) — agent loop, tool descriptions
- [../observational-memory.md](../observational-memory.md) — observation injection

## Specification

### 1. System Prompt

The system prompt is assembled dynamically and includes:
1. **Role definition** — "You are Deft, an AI coding agent..."
2. **Tool descriptions** — generated from registered tools' `name/0`, `description/0`, and `parameters/0` callbacks
3. **Working directory context** — current path, git branch if applicable
4. **Date and environment** — current date, OS, shell
5. **Conflict resolution** — "If observations conflict with current messages, messages take precedence. If observations conflict with project instructions, project instructions take precedence."

The system prompt does NOT include observation text — that is injected separately by the OM system. Project instructions are included in the context assembly as a separate message (see section 2, item 4).

### 2. Message List Assembly

On each turn, the context is assembled in this order:
1. **System prompt** — static instructions
2. **Observation injection** — if OM is active, observations as a system message (see [../observational-memory.md](../observational-memory.md))
3. **Conversation history** — messages from the current session, minus observed-and-trimmed messages
4. **Project context** — contents of `DEFT.md`, `CLAUDE.md`, or `AGENTS.md`

### 3. Token Tracking

The agent tracks token usage from provider usage reports:
- `total_input_tokens` — cumulative input tokens across all turns
- `total_output_tokens` — cumulative output tokens across all turns
- `current_context_tokens` — estimated tokens in the current message list
- `context_window` — the model's context window size

When OM is not active, a compaction fallback exists: if `current_context_tokens > 0.7 * context_window`, oldest messages are summarized and replaced.

### 4. Cost Tracking

Tracks estimated cost per model per turn from `:usage` events and model pricing:
- `session_cost` — cumulative estimated cost (Actor + OM calls)
- Displayed in TUI status bar, persisted in session JSONL

## References

- [../harness.md](../harness.md) — agent loop
- [../observational-memory.md](../observational-memory.md) — observation injection
- [persistence.md](persistence.md) — JSONL entry types including cost entries
