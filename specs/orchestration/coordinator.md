# Foreman.Coordinator

| | |
|--------|----------------------------------------------|
| Version | 0.17 |
| Status | Ready |
| Last Updated | 2026-04-10 |

## Changelog

### v0.17 (2026-04-10)
- Extracted from orchestration.md with new naming (Foreman gen_statem → Foreman.Coordinator)
- Incorporates all code-speed coordination behavior from v0.10–v0.16

## Overview

The Foreman.Coordinator is a gen_statem that handles code-speed process management on behalf of the Foreman. It exists because during orchestration, deterministic coordination (contract forwarding, crash handling, monitor management) must happen while the Foreman is in the middle of an LLM call. The Coordinator never calls the LLM — it manages processes, routes messages, and enforces timeouts.

**Scope:**
- Job phase state machine (7 states)
- Foreman↔Coordinator interface
- DAG validation and management
- Contract auto-forwarding
- Lead message coalescing
- Monitor management (Leads, Store, RateLimiter)
- Crash handling and recovery
- Cleanup on all exit paths

**Out of scope:**
- LLM reasoning, tool execution (see [foreman.md](foreman.md))
- Lead internals (see [lead.md](lead.md))
- Message format definitions (see [protocol.md](protocol.md))

**Dependencies:**
- [foreman.md](foreman.md) — the Foreman agent this Coordinator serves
- [lead.md](lead.md) — Lead + Lead.Coordinator processes
- [../rate-limiter.md](../rate-limiter.md) — RateLimiter process
- [../filesystem.md](../filesystem.md) — Deft.Store
- [../git-strategy.md](../git-strategy.md) — worktree management

## Specification

### 1. State Machine

The Foreman.Coordinator has seven states — job phases only:

```
:asking --> :planning --> :researching --> :decomposing --> :executing --> :verifying --> :complete
```

In solo mode, the Coordinator stays in `:asking` and the Foreman handles everything. The Coordinator only transitions through the full lifecycle when the Foreman uses orchestration tools.

### 2. Foreman → Coordinator Communication

The Foreman's orchestration tools send messages to the Coordinator:

```
Foreman calls `submit_plan` tool
  → tool implementation: send(coordinator_pid, {:agent_action, :plan, deliverables})
  → tool returns :ok to Foreman
  → Coordinator receives message in handle_info, takes action
```

### 3. Coordinator → Foreman Communication

The Coordinator prompts the Foreman via `Deft.Agent.prompt/2` when:
- Research Runners complete (sends findings)
- Lead messages need Foreman attention (after coalescing)
- User input arrives during execution
- Crash events need triage

The Coordinator must use the Foreman's registered name (via-tuple) for all `Deft.Agent.prompt/2` calls, not a cached PID.

### 4. Code-Speed vs LLM-Speed Boundary

**Code-speed (Coordinator handles directly, notifies Foreman after):**
- Contract matching: published contracts are matched against the plan's dependency DAG and forwarded to blocked Lead.Coordinators immediately
- Lead completion bookkeeping: tracking set updates, monitor cleanup, worktree cleanup
- Crash timeout enforcement: auto-fail a crashed Lead's deliverable if Foreman doesn't respond within the configured timeout
- DAG validation on `submit_plan`: all IDs valid, no self-loops, no cycles (topological sort)

**LLM-speed (routed to Foreman as prompts):**
- Steering decisions (steer, abort, retry)
- Plan creation and amendment
- Research synthesis
- Crash triage (retry vs. fail) — but with a timeout fallback

### 5. Lead Message Coalescing

Low-priority Lead.Coordinator messages (`:status`, `:artifact`, `:decision`, `:finding`, `:contract`, `:contract_revision`) are buffered. High-priority messages (`:blocker`, `:complete`, `:error`, `:critical_finding`) flush the buffer and are forwarded immediately.

The buffer uses a **max-age flush** strategy. The Coordinator tracks `buffer_start_time` — the timestamp when the first message entered an empty buffer. On each new low-priority message: if `now - buffer_start_time >= debounce_ms`, flush immediately; otherwise, append to the buffer and leave the existing timer running. The timer is set once when the first message arrives and is NOT reset on subsequent messages.

The flush timer handler must check the `foreman_restarting` flag. When true, the handler must be a no-op — leave the buffer intact for the restart catch-up prompt.

`:contract` is low-priority because contract auto-unblocking already happened at code speed. The Foreman notification is informational.

### 6. Contract Auto-Forwarding

The Coordinator receives `{:lead_message, :contract, content, metadata}` from Lead.Coordinators and immediately matches the contract against the plan's dependency DAG. For each match, the Coordinator sends `{:coordinator_contract, contract}` to the blocked Lead.Coordinator directly — no LLM round-trip.

After auto-forwarding, the Coordinator notifies the Foreman: "Contract X published by Lead A, auto-forwarded to Lead B." The Foreman retains override capability (it can still call `abort_lead` or `steer_lead`).

The `unblock_lead` tool remains for manual overrides — e.g., when the Foreman decides to unblock a Lead with a synthesized contract.

### 7. Monitor Management

The Coordinator monitors:
- All Lead.Coordinators via `Process.monitor`
- The Foreman via `Process.monitor`
- Store and RateLimiter via `Process.monitor`

Store and RateLimiter use `restart: :temporary` — they are never restarted. On crash, the Coordinator fails the job with cleanup.

The Coordinator looks up RateLimiter and Store by registered name on each use. It must NOT cache PIDs at init.

### 8. Crash Handling

**Lead crash:** Coordinator notifies the Foreman and starts a configurable timeout (default 60s). If the Foreman does not call `fail_deliverable` or `spawn_lead` within the timeout, the Coordinator auto-fails the deliverable.

**Foreman crash:** The Coordinator attempts one restart — start a new Foreman with the session JSONL for conversation continuity, re-establish the monitor, and send a catch-up prompt with current job state. During the restart window, the Coordinator continues handling code-speed operations but buffers all messages that would go to the Foreman. If restart fails or the restarted Foreman crashes again, fail the job with full cleanup.

**Store / RateLimiter crash:** Unrecoverable — fail the job with full cleanup.

### 9. Cleanup

The Coordinator's `cleanup/1` runs on **every exit path** — normal completion, failure, abort, and crash (via `terminate/3`). Each step wrapped in `try/rescue`:

1. **Monitors:** Demonitor all Leads (with `:flush`), the Foreman, Store, and RateLimiter.
2. **Lead processes:** Stop each Lead's supervisor subtree via `DynamicSupervisor.terminate_child`.
3. **Worktrees:** Call `GitJob.cleanup_lead_worktree` for each Lead with a worktree (after Lead processes stopped).
4. **Site log:** Stop the Store process if alive.

On Foreman crash: demonitor all Leads with `:flush` first, then return `{:stop, ...}` and let `terminate/3` call `cleanup/1`.

On Lead abort (`do_abort_lead`): Must stop the Lead's entire supervisor subtree via `DynamicSupervisor.terminate_child` — not `Process.exit` on the Lead.Coordinator alone. Then clean up worktree.

### 10. Merge Strategy

Each Lead works in its own git worktree (see [../git-strategy.md](../git-strategy.md)). When a Lead completes, the Coordinator merges the Lead's branch into the job branch, spawning a merge-resolution Runner if conflicts arise. Merge order follows the dependency DAG; independent Leads are merged in completion order.

On job completion, all work is squash-merged into the original branch.

### 11. Conflict Detection

**File-overlap detection (code speed):** The Coordinator tracks which files each Lead has modified via `:artifact` messages. On overlap, the Coordinator pauses both affected Leads and sends the conflict to the Foreman.

**Semantic conflict detection (LLM speed):** `:decision` messages are routed to the Foreman via the standard coalescing path. The Foreman reviews decisions from multiple Leads and identifies logical conflicts.

### 12. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.max_leads` | `5` | Maximum concurrent Leads per job |
| `job.lead_message_debounce` | `2_000` | Debounce timer for low-priority Lead messages (ms) |
| `job.lead_crash_decision_timeout` | `60_000` | Timeout for Foreman to decide retry/fail after Lead crash (ms) |

### 13. Job Persistence

Jobs are stored at `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/`:
- `sitelog.dets` — the Deft.Store site log persistence
- `plan.json` — the approved work plan (snapshot for resume)

The Foreman's session JSONL lives in the normal sessions directory (it is the user's session).

On resume, the Coordinator reads the site log to reconstruct job knowledge and plan.json for coordination state. For each incomplete deliverable, it starts a fresh Lead + Lead.Coordinator pair with instructions that account for already-completed work. Lead sessions are NOT restored — fresh Leads are simpler and more reliable.

## References

- [foreman.md](foreman.md) — the Foreman agent
- [lead.md](lead.md) — Lead + Lead.Coordinator
- [protocol.md](protocol.md) — message types
- [../git-strategy.md](../git-strategy.md) — worktree management
- [../rate-limiter.md](../rate-limiter.md) — rate limiter
- [../filesystem.md](../filesystem.md) — Deft.Store
