# Orchestration

| | |
|--------|----------------------------------------------|
| Version | 0.17 |
| Status | Ready |
| Last Updated | 2026-04-10 |

## Changelog

### v0.17 (2026-04-10)
- Restructured into sub-specs: foreman, coordinator, lead, runners, protocol
- Renamed ForemanAgent → Foreman, Foreman (gen_statem) → Foreman.Coordinator, LeadAgent → Lead, Lead (gen_statem) → Lead.Coordinator
- Unified entry point: every session starts a Foreman. No separate "plain agent" path. `Session.Worker` starts the Foreman subtree. `deft work` is just a session with an issue as the first prompt.

### v0.16 (2026-04-07)
- Flush timer must check `foreman_agent_restarting` flag

### v0.15 (2026-04-07)
- Fix Lead `:complete` state ordering: check queued steering before sending `:complete` to Foreman

### v0.14 (2026-04-07)
- Expert review: 10 findings across supervision, state machine, and code-speed boundary

### v0.13 (2026-04-01)
- Fix `all_leads_complete?` to track outcomes per deliverable, not per lead

### v0.12 (2026-04-01)
- Max-age flush replaces sliding-window debounce
- Process lifecycle fixes for lead completion, crash retry, and ForemanAgent crash cleanup

### v0.11 (2026-03-31)
- Reclassified `:contract` and `:contract_revision` as low-priority for message coalescing
- Worktree cleanup ordering fixes

### v0.10 (2026-03-31)
- Code-speed orchestration, process lifecycle correctness, sibling process resilience, cost ceiling gating

### v0.9 (2026-03-30)
- Added: ForemanAgent tool `fail_deliverable`

### v0.8 (2026-03-30)
- Added: Foreman must monitor the ForemanAgent via `Process.monitor`

### v0.7 (2026-03-29)
- Split Foreman and Lead into orchestrator + agent process pairs

### v0.6 (2026-03-19)
- User corrections via explicit `/correct` command only

### v0.5 (2026-03-19)
- Foreman delegates tool execution to `Deft.Tool.execute/3`

### v0.4 (2026-03-19)
- Lead "runs compile checks" means spawning a testing Runner

### v0.3 (2026-03-17)
- Split rate limiter and git strategy into separate specs

### v0.2 (2026-03-17)
- Site Log → OTP messages + Deft.Store

### v0.1 (2026-03-16)
- Initial spec — Foreman/Lead/Runner hierarchy

## Overview

Orchestration is Deft's system for breaking complex tasks into parallel work streams. Every session starts with a **Foreman** — the agent the user talks to. The Foreman decides whether to handle a task directly (solo mode) or decompose it into deliverables managed by **Leads** (orchestrated mode). A **Foreman.Coordinator** handles code-speed process management while the Foreman thinks. **Leads** manage individual deliverables, each paired with a **Lead.Coordinator**. **Runners** execute short-lived tasks.

**Naming:**

| Name | What it is | What it does |
|------|-----------|-------------|
| **Foreman** | `Deft.Agent` — LLM loop, OM, session | The agent the user talks to. Analyzes tasks, makes decisions, uses tools. Owns the session. |
| **Foreman.Coordinator** | `gen_statem` — pure coordination | Code-speed process management. DAG, monitors, contract forwarding, message coalescing, Lead lifecycle, cleanup. No LLM calls. |
| **Lead** | `Deft.Agent` — LLM loop, OM | Manages one deliverable. Decomposes work, steers Runners, evaluates output. |
| **Lead.Coordinator** | `gen_statem` — pure coordination | Runner management, contract publishing, reporting to Foreman.Coordinator. No LLM calls. |
| **Runner** | Short-lived Task | Executes a single task (research, implementation, testing, review, merge resolution). Inline loop, no OM. |

**Unified entry point:** Every session — web UI, `deft -p`, `deft work` — starts a Foreman. There is no separate "plain agent" mode. The Foreman handles simple tasks directly (solo mode) and orchestrates complex tasks by spawning Leads. The only difference between entry points is what the first prompt is.

**Scope:**
- Session process tree (unified — same tree for all entry points)
- Foreman behavior (solo mode, orchestrated mode, job lifecycle)
- Foreman.Coordinator behavior (DAG, monitors, coalescing, cleanup)
- Lead + Lead.Coordinator behavior
- Runner roles and tool sets
- Coordination protocol (message types, site log)
- User interaction during execution

**Out of scope:**
- Git worktree strategy (see [../git-strategy.md](../git-strategy.md))
- Rate limiting and cost tracking (see [../rate-limiter.md](../rate-limiter.md))
- The `Deft.Agent` abstraction itself (see [../harness.md](../harness.md))
- Observational memory internals (see [../observational-memory.md](../observational-memory.md))

**Dependencies:**
- [../harness.md](../harness.md) — `Deft.Agent` gen_statem, tools, provider layer, session persistence
- [../sessions/README.md](../sessions/README.md) — session persistence, context management
- [../observational-memory.md](../observational-memory.md) — per-agent context management
- [../filesystem.md](../filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [../rate-limiter.md](../rate-limiter.md) — centralized rate limiting for LLM calls
- [../git-strategy.md](../git-strategy.md) — worktree strategy for parallel Lead execution

**Design principles:**
- **One entry point.** Every session is a Foreman. The Foreman decides the execution strategy. The user never picks between "simple" and "orchestrated" modes.
- **Foreman = the agent, Coordinator = the plumbing.** The Foreman is the thing that thinks. The Coordinator is the thing that manages processes. Users see "the Foreman." The Coordinator is an internal necessity for async orchestration.
- **Flat hierarchy, direct communication.** No message relay chains. Coordinators communicate via direct PID.
- **Deliverable-level decomposition.** The Foreman plans big, coherent chunks of work — not individual implementation steps.
- **Leads are the brains.** Leads own their deliverable end-to-end: decompose, steer, course-correct, refine.
- **Runners are lightweight.** Short-lived inline loops. No OM, no persistent state.
- **Partial unblocking.** A Lead starts as soon as the specific information it needs (interface contract) is available.

## Process Architecture

Every session starts the same tree:

```
Session.Worker (rest_for_one)
├── Deft.Store (site log — ETS+DETS)
├── Deft.RateLimiter
├── Deft.Agent.ToolRunner (Foreman's tool execution)
├── Deft.Foreman (Deft.Agent — LLM loop, OM, session JSONL)
├── Task.Supervisor (research/verification Runners)
├── Deft.OM.Supervisor
│   ├── Task.Supervisor
│   └── Deft.OM.State
├── Deft.Foreman.Coordinator (gen_statem — orchestration)
└── Deft.LeadSupervisor (DynamicSupervisor)
    └── [per lead, on demand]
        Lead.Supervisor (one_for_one)
        ├── Deft.Agent.ToolRunner (Lead's tool execution)
        ├── Deft.Lead (Deft.Agent — LLM loop, OM)
        ├── Task.Supervisor (Lead's Runners)
        └── Deft.Lead.Coordinator (gen_statem)
```

The tree is the same regardless of entry point:
- **Web UI** — user types a message, it becomes the Foreman's first prompt
- **`deft -p "prompt"`** — prompt from CLI flag, exit after response
- **`deft work`** — issue becomes the Foreman's first prompt
- **`deft work --loop`** — sequential sessions, each with an issue as the first prompt

For simple tasks, the LeadSupervisor stays empty. The Foreman handles everything directly in solo mode.

## Included Specs

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [foreman](foreman.md) | v0.17 | Ready | Foreman agent — session ownership, solo/orchestrated modes, job lifecycle, user interaction |
| [coordinator](coordinator.md) | v0.17 | Ready | Foreman.Coordinator — DAG management, contract forwarding, message coalescing, monitors, crash handling, cleanup |
| [lead](lead.md) | v0.17 | Ready | Lead + Lead.Coordinator — deliverable management, Runner steering, contracts, reporting |
| [runners](runners.md) | v0.17 | Ready | Runner types, tool sets, inline loop, context from Lead |
| [protocol](protocol.md) | v0.17 | Ready | Coordination protocol, message types, site log write policy |

## Notes

### Design decisions

- **Unified entry point over separate agent/job paths.** The original design had two paths: a plain `Deft.Agent` for simple conversations and a `Job.Supervisor` for orchestrated work. This forced the user (or CLI command) to choose the execution mode upfront. The Foreman's single-agent fallback already handled simple tasks — there was no reason to maintain a separate path that couldn't orchestrate.
- **Foreman/Coordinator split over single process.** The Foreman (LLM agent) and Coordinator (process manager) are separate processes because during orchestration, the Coordinator must handle code-speed events (contract forwarding, crash timeouts, monitor handling) while the Foreman is in the middle of an LLM call. A single process would either block coordination during thinking or require complex async state management.
- **Coordinator named explicitly over hidden implementation detail.** The Coordinator has real specified behavior (coalescing strategy, DAG validation, crash timeout policy, cleanup ordering). Hiding it behind "the Foreman handles this internally" makes the spec less clear about who does what and when.
- **Deliverable-level decomposition over file-level.** Real work has overlapping files. The dependency DAG handles integration; git worktrees handle file isolation.
- **Code-speed orchestration over LLM-mediated everything.** Deterministic coordination (contract DAG matching, completion bookkeeping, crash timeouts) should not require an LLM round-trip.

## References

- [../harness.md](../harness.md) — Deft.Agent gen_statem, tools, provider layer
- [../sessions/README.md](../sessions/README.md) — session persistence, context management
- [../observational-memory.md](../observational-memory.md) — per-agent context management
- [../filesystem.md](../filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [../rate-limiter.md](../rate-limiter.md) — centralized rate limiting for LLM calls
- [../git-strategy.md](../git-strategy.md) — git worktree strategy for parallel Lead execution
