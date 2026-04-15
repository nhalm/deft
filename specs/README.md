# Deft Specifications

> An AI coding agent with observational memory

## How Specs Work

Specs are **steering documents** — they define WHAT to build and WHY, not HOW to implement.

**Workflow:**

1. **Spec phase** — We work through a spec until it's right
2. **Loop phase** — `loop.sh` runs agents that implement the spec
3. **History** — [specd_history.md](../specd_history.md) records what's been implemented (done log)

**Agents have autonomy** on implementation. The spec steers direction, the agent decides the code.

**Status transitions.** Humans move specs from Draft → Ready. The `/specd:audit` command manages Ready ↔ Implemented transitions — promoting clean specs to Implemented, demoting specs with new findings back to Ready.

**Future items:** Items marked with `(future)` are for reference only. Do not implement them — they belong to a later phase or another spec.

**Dependencies:** If a feature depends on another spec, check that spec's status. Only implement if the dependency is Ready or Implemented. Mark blocked features with "(blocked: specname)".

**Versioning:** Specs use `v{major}.{minor}` versioning. Minor versions increment sequentially — v0.9 is followed by v0.10, not v1.0. Only increment the major version when explicitly instructed.

**Cross-references:** When referencing another spec in the body (Out of scope, Dependencies, inline text), use a real markdown link with the correct relative path. Changelog entries are historical records and use plain text names.

## Changelogs

Each spec has a Changelog section with human-readable summaries of what changed per version. Changelogs are a historical record — they describe WHAT changed and WHY, not granular implementation tasks.

```markdown
### v0.4 (2026-03-02)

- Added business user authentication alongside existing platform users
```

**Work items** live in [specd_work_list.md](../specd_work_list.md), not in spec changelogs. The `/specd:audit` command generates work items directly in specd_work_list.md based on gaps between specs and code. Humans and planning agents can also write directly to specd_work_list.md during spec phase.

## History (Done Log)

[specd_history.md](../specd_history.md) is a record of completed work in reverse chronological order (newest first). Loop agents add entries after completing a work item. It prevents duplicate work and shows progress.

specd_history.md does NOT contain "Remaining" lists. [specd_work_list.md](../specd_work_list.md) is the source of truth for remaining work. An item is done when it's in specd_history.md.

Decision reasoning is logged in [specd_decisions.jsonl](../specd_decisions.jsonl) — see AGENTS.md for format.

## Status Legend

| Status      | Meaning                                                |
| ----------- | ------------------------------------------------------ |
| Draft       | Being specified — not ready for implementation         |
| Ready       | Spec complete, ready for implementation                |
| Implemented | Fully implemented                                      |
| Deprecated  | Superseded by another spec — kept for legacy reference |

---

## Foundation

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [standards](standards.md) | v0.4 | Implemented | Elixir coding standards, Makefile, git hooks, testing strategy |
| [testing](testing/README.md) | v0.1 | Implemented | Testing strategy — three layers (unit, integration, eval), ScriptedProvider, coverage expectations |
| [unit-testing](testing/unit-testing.md) | v0.1 | Implemented | Unit testing philosophy, critical path coverage, ScriptedProvider integration scenarios |
| [evals](testing/evals/README.md) | v0.5 | Implemented | AI eval infrastructure, methodology, and component eval definitions |
| [harness](harness.md) | v0.5 | Implemented | Agent loop (gen_statem), message format, process architecture, standalone + sub-agent modes, optional RateLimiter integration |
| [tools](tools.md) | v0.3 | Implemented | Tool behaviour, 7 built-in tools, orchestration tools, tool execution model |
| [providers](providers.md) | v0.3 | Implemented | LLM provider behaviour, SSE streaming, Anthropic implementation |
| [sessions](sessions/README.md) | v0.9 | Implemented | Session persistence, context management, runtime, and branching |
| [sessions/persistence](sessions/persistence.md) | v0.8 | Implemented | JSONL storage format, entry types, storage paths, resume, listing, checkpoint entries |
| [sessions/context](sessions/context.md) | v0.8 | Implemented | System prompt assembly, message list construction, token tracking, compaction, cost tracking |
| [sessions/runtime](sessions/runtime.md) | v0.9 | Implemented | Configuration, CLI dispatcher, Phoenix application, distribution |
| [sessions/branching](sessions/branching.md) | v0.1 | Implemented | User-initiated session forking from checkpoints with git state restore |
| [tui](tui.md) | v0.5 | Deprecated | Terminal UI — superseded by web-ui |
| [web-ui](web-ui.md) | v0.9 | Implemented | Phoenix LiveView web interface, vim/tmux keybindings, responsive, real-time streaming |

## Core

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [observational-memory](observational-memory.md) | v0.3 | Implemented | Observer/Reflector with sectioned observations, two-level compression |
| [orchestration](orchestration/README.md) | v0.17 | Implemented | Unified session/Foreman architecture — Foreman, Coordinator, Lead, Runners |
| [orchestration/foreman](orchestration/foreman.md) | v0.17 | Implemented | Foreman agent — session ownership, solo/orchestrated modes, job lifecycle |
| [orchestration/coordinator](orchestration/coordinator.md) | v0.17 | Implemented | Foreman.Coordinator — DAG, contract forwarding, coalescing, monitors, cleanup |
| [orchestration/lead](orchestration/lead.md) | v0.17 | Implemented | Lead + Lead.Coordinator — deliverable management, Runner steering, contracts |
| [orchestration/runners](orchestration/runners.md) | v0.18 | Implemented | Runner types, tool sets, inline loop |
| [orchestration/protocol](orchestration/protocol.md) | v0.17 | Implemented | Coordination protocol, message types, site log write policy |
| [rate-limiter](rate-limiter.md) | v0.4 | Implemented | Dual token-bucket rate limiting, priority queue, adaptive concurrency, cost tracking |
| [git-strategy](git-strategy.md) | v0.3 | Implemented | Git worktree strategy, merge protocol, conflict resolution, orphan cleanup |

## Infrastructure

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [filesystem](filesystem.md) | v0.4 | Implemented | Deft.Store GenServer — ETS+DETS for cache and site log, cache_read tool, per-tool spilling thresholds |
| [skills](skills.md) | v0.4 | Implemented | Skills (agent-selected YAML) and commands (markdown prompts), three-level cascade |
| [issues](issues.md) | v0.6 | Implemented | Persistent issue tracker — JSONL+git, interactive creation, approve-every-plan `deft work` loop |

## Operations

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [logging](logging.md) | v0.7 | Implemented | Configurable log levels, per-layer logging requirements, message conventions |

## Future

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| security | — | — | Tool permissions, sandboxing, secret redaction, project file sanitization |
| mcp | — | — | Model Context Protocol integration for external tools |
| cross-session-memory | — | — | Resource-scoped OM across sessions (Mastra's resource scope) |
