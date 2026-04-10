# Foreman

| | |
|--------|----------------------------------------------|
| Version | 0.17 |
| Status | Implemented |
| Last Updated | 2026-04-10 |

## Changelog

### v0.17 (2026-04-10)
- Extracted from orchestration.md with new naming (ForemanAgent → Foreman)
- Unified entry point: every session starts a Foreman. Solo mode replaces "single-agent fallback."
- Foreman owns the session — conversation history, OM state, session JSONL

## Overview

The Foreman is the agent the user talks to. It is a standard `Deft.Agent` instance that owns the session — conversation history, OM state, and session persistence. For simple tasks, the Foreman handles everything directly (solo mode). For complex tasks, the Foreman plans work, decomposes it into deliverables, and delegates to Leads via the [Foreman.Coordinator](coordinator.md).

**Scope:**
- Solo mode (direct task execution)
- Orchestrated mode (planning, research, decomposition, steering, verification)
- Job lifecycle phases
- Foreman tool set (standard tools + orchestration tools)
- User interaction

**Out of scope:**
- Code-speed coordination (see [coordinator.md](coordinator.md))
- Lead behavior (see [lead.md](lead.md))
- Runner behavior (see [runners.md](runners.md))

**Dependencies:**
- [../harness.md](../harness.md) — `Deft.Agent` behavior
- [coordinator.md](coordinator.md) — the Foreman.Coordinator that manages processes on the Foreman's behalf
- [../sessions/persistence.md](../sessions/persistence.md) — session JSONL

## Specification

### 1. Session Ownership

The Foreman is the session. It is started by `Session.Worker` and is the sole `Deft.Agent` that writes to the user's session JSONL. It has OM enabled. Every session, regardless of entry point (web UI, `deft -p`, `deft work`), starts a Foreman.

### 2. Solo Mode

For simple tasks (touches 1-2 files, no natural decomposition, estimated < 3 Runner tasks), the Foreman executes directly with a full tool set: read, write, edit, bash, grep, find, ls. No Leads are spawned. The Foreman.Coordinator exists but stays idle.

This is the default mode for conversational use. The user asks a question, the Foreman answers. The user asks for a code change, the Foreman makes it. No orchestration overhead.

### 3. Orchestrated Mode

For complex tasks, the Foreman transitions through job lifecycle phases. It communicates with the Foreman.Coordinator via orchestration tools — tool calls that send messages to the Coordinator process.

#### 3.1 Orchestration Tools

The Foreman has these tools in addition to standard file/bash tools. Each tool sends a message to the Foreman.Coordinator and returns `:ok` to the agent:

| Tool | Message to Coordinator | Purpose |
|------|----------------------|---------|
| `ready_to_plan` | `{:agent_action, :ready_to_plan}` | Signal that Q&A is complete, transition to `:planning` |
| `request_research` | `{:agent_action, :research, topics}` | Fan out research to Runners |
| `submit_plan` | `{:agent_action, :plan, deliverables}` | Present decomposition for approval |
| `spawn_lead` | `{:agent_action, :spawn_lead, deliverable}` | Start a Lead for a deliverable. On retry, must clear `deliverable_outcomes` for that deliverable before spawning. |
| `unblock_lead` | `{:agent_action, :unblock_lead, lead_id, contract}` | Manually unblock a Lead (override only — see [coordinator.md](coordinator.md) for auto-unblocking) |
| `steer_lead` | `{:agent_action, :steer_lead, lead_id, content}` | Send course correction to a Lead |
| `abort_lead` | `{:agent_action, :abort_lead, lead_id}` | Stop a Lead |
| `fail_deliverable` | `{:agent_action, :fail_deliverable, lead_id}` | Mark a deliverable as failed (after crash or unrecoverable blocker) |

In solo mode, orchestration tools are available but the Foreman naturally ignores them — there are no Leads to steer.

#### 3.2 Job Lifecycle Phases

The Foreman's behavior during orchestration follows these phases. The Foreman.Coordinator tracks the current phase and manages transitions.

| Phase | Foreman does |
|-------|-------------|
| `:asking` | Analyzes user request, asks clarifying questions about scope, constraints, edge cases. Calls `ready_to_plan` when satisfied. For simple/unambiguous requests, may call `ready_to_plan` immediately. |
| `:planning` | Receives accumulated context from Q&A, calls `request_research` with topics |
| `:researching` | Receives research findings from Runners (delivered by Coordinator), calls `submit_plan` with deliverables and DAG |
| `:decomposing` | (idle — waiting for user to approve plan) |
| `:executing` | Receives Lead progress/blockers (delivered by Coordinator), calls `steer_lead`/`unblock_lead`/`spawn_lead` as needed |
| `:verifying` | (idle — waiting for verification Runner) |
| `:complete` | Generates summary for user |

**Auto-approve:** When `--auto-approve-all` is set, the asking phase is skipped — the Foreman works with whatever context the prompt provides. Plan approval is also skipped. For non-interactive mode (`deft -p "prompt"`), `--auto-approve-all` is required since no user is present to approve plans.

### 4. Tool Sets

| Mode | Tools |
|------|-------|
| Solo | read, write, edit, bash, grep, find, ls (+ orchestration tools, unused) |
| Orchestrated | read, grep, find, ls (read-only) + orchestration tools. The Foreman does not modify files during orchestration — Leads do the implementation. |

The Coordinator controls which mode via the initial prompt context.

### 5. User Interaction

The user interacts with the Foreman through the normal web UI chat interface.

| Action | How |
|--------|-----|
| Check status | `/status` or ask the Foreman |
| Redirect | "Focus on the backend first" |
| Send correction | `/correct <message>` — auto-promoted to site log |
| Abort a deliverable | "Stop working on the frontend" |
| Abort entire job | Ctrl+C or `/abort` (cleans up all worktrees) |
| Add context | "By the way, we use Ecto for the database layer" |
| Modify plan | "Split the backend into API and middleware" |
| Inspect Lead work | `/inspect lead-a` |
| Create checkpoint | `/checkpoint <label>` (see [../sessions/branching.md](../sessions/branching.md)) |
| Branch session | `/branch <label>` (see [../sessions/branching.md](../sessions/branching.md)) |

User messages arrive at the Foreman.Coordinator, which decides whether to forward them to the Foreman as prompts or handle them directly (e.g., `/abort` is handled by the Coordinator without LLM involvement).

### 6. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.foreman_model` | `"claude-sonnet-4"` | Model for the Foreman |
| `job.max_duration` | `1_800_000` | Maximum job duration (ms, default 30 min) |

## References

- [coordinator.md](coordinator.md) — Foreman.Coordinator
- [lead.md](lead.md) — Lead agents
- [../harness.md](../harness.md) — Deft.Agent
- [../sessions/persistence.md](../sessions/persistence.md) — session JSONL
