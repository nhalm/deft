# Orchestration

| | |
|--------|----------------------------------------------|
| Version | 0.16 |
| Status | Ready |
| Last Updated | 2026-04-07 |

## Changelog

### v0.16 (2026-04-07)
- **Flush timer must check `foreman_agent_restarting` flag.** The `:flush_lead_messages` timer handler must guard against the `foreman_agent_restarting` flag. A debounce timer set before ForemanAgent crash can fire during the restart window, sending a prompt to the dead/restarting agent and clearing the buffer (losing messages that should be in the restart catch-up prompt). When `foreman_agent_restarting` is true, the flush handler must be a no-op — leave the buffer intact for the catch-up prompt.

### v0.15 (2026-04-07)
- **Fix Lead `:complete` state ordering: check queued steering before sending `:complete` to Foreman.** The previous spec said to send `:complete` first, then apply queued steering. This causes the Foreman to remove the Lead from tracking and mark the deliverable done before the Lead potentially re-enters `:executing`. The Lead's subsequent work becomes invisible to the Foreman. The correct sequence is: check queued steering first; if steering triggers re-execution, re-enter `:executing` without sending `:complete`.

### v0.14 (2026-04-07)
- **Expert review: 10 findings across supervision, state machine, and code-speed boundary.** Three-reviewer audit validated against code. Key changes:
- Fix retry/auto-fail race: `spawn_lead` must clear `deliverable_outcomes` for the retried deliverable, preventing premature `:verifying` transition.
- Lead abort must use `DynamicSupervisor.terminate_child` (not `Process.exit`), cascading shutdown to LeadAgent, ToolRunner, and RunnerSupervisor. Worktree cleanup must wait for the supervisor to confirm child termination.
- Store and RateLimiter need an explicit failure strategy: Foreman must monitor both and fail the job on crash (they are `:temporary` and never restart).
- Rewrite §4.7 conflict detection: file-overlap detection at code speed, semantic conflicts routed to ForemanAgent via the existing coalescing path.
- Add DAG cycle validation in `submit_plan` handling (topological sort).
- ForemanAgent crash: attempt one restart from session JSONL before failing the job. During the restart window, the Foreman remains in `:executing` with a `foreman_agent_restarting` flag — not a new state.
- Foreman must use ForemanAgent's registered name (via-tuple) for all `Deft.Agent.prompt/2` calls, not a cached PID.
- All cleanup steps must be wrapped in try/rescue to prevent cascading failures.
- Lead steering in `:verifying` must be queued and applied after verification completes (not discarded).

### v0.13 (2026-04-01)
- **Fix `all_leads_complete?` to track outcomes per deliverable, not per lead.** The current `completed_leads + failed_leads == length(deliverables)` check breaks after a Lead retry: the crashed Lead's ID goes into `failed_leads` and the replacement Lead's ID goes into `completed_leads`, giving a count of 2 for a single deliverable. The Foreman must track which deliverables have a final outcome (completed or definitively failed), not count distinct lead IDs. `all_leads_complete?` returns `true` when every deliverable has an outcome.

### v0.12 (2026-04-01)
- **Max-age flush replaces sliding-window debounce.** The debounce timer must use a max-age strategy: track `buffer_start_time` when the first message enters an empty buffer. On each new message, if `now - buffer_start_time >= debounce_ms`, flush immediately. Otherwise, leave the existing timer running (do NOT reset it on each message). This guarantees the agent receives updates every `debounce_ms` regardless of message rate. The prior sliding-window design reset the timer on every message, which starved the timer under sustained load — 4 Leads at 3 msg/sec means a message every ~83ms, so a 2s timer never fires.
- `handle_lead_completion` must guard against absent lead_id: check `Map.has_key?(data.leads, lead_id)` before mutating tracking sets. A late `:complete` message for an already-failed/aborted Lead must be ignored, not added to `completed_leads` (which would put it in both `completed_leads` and `failed_leads`).
- On Lead crash retry via `spawn_lead`: `cancel_crash_decision_timer_for_deliverable` must also remove the old crashed lead_id from `started_leads` and add to `failed_leads`. Otherwise the old lead_id is orphaned in `started_leads` permanently.
- `do_fail_job_on_foreman_agent_crash` and the `:abort` handler must not call `cleanup(data)` before returning `{:stop, ...}` — `terminate/3` already calls it. Remove the explicit pre-stop cleanup to avoid triple/double invocation. For ForemanAgent crash: demonitor all Leads with `:flush` first (to prevent spurious DOWNs), then return `{:stop, ...}` and let `terminate/3` handle the rest.

### v0.11 (2026-03-31)
- Reclassified `:contract` and `:contract_revision` as low-priority for message coalescing. Since contract auto-unblocking already happens at code speed, the ForemanAgent notification is informational and does not need to flush the buffer. High-priority set is now: `:blocker`, `:complete`, `:error`, `:critical_finding`.
- `do_abort_lead` must call `GitJob.cleanup_lead_worktree` before removing the Lead from `data.leads`. Previously the worktree was leaked because removal from the map prevented `cleanup/1` from finding it.
- `fail_deliverable` must demonitor the Lead (if still monitored) and clean up the worktree when called on a non-crashed Lead. When called after a crash, `do_handle_lead_crash` already handled both — `fail_deliverable` must be safe for both paths.
- `do_fail_job_on_foreman_agent_crash` must demonitor all Leads with `:flush` FIRST, then do cleanup. Previously demonitors happened after `cleanup(data)`, creating a window for spurious DOWN messages. Also remove the redundant manual Lead stop and worktree cleanup — `cleanup(data)` already handles both.
- Pass RateLimiter registered name (not cached PID) to Leads when spawning them via `start_lead_process`.

### v0.10 (2026-03-31)
- **Code-speed orchestration.** The Foreman handles deterministic coordination at code speed and notifies the ForemanAgent asynchronously. Three changes: (1) contract auto-unblocking — Foreman matches published contracts against the plan's dependency DAG and forwards to blocked Leads immediately, notifying ForemanAgent after the fact; (2) Lead message coalescing — low-priority Lead messages (`:status`, `:artifact`) are buffered with a short debounce timer and sent as a single consolidated prompt, while high-priority messages (`:contract`, `:blocker`, `:complete`, `:error`) flush the buffer immediately; (3) crash recovery timeout — if ForemanAgent does not call `fail_deliverable` or `spawn_lead` within a configurable timeout after a Lead crash notification, the Foreman auto-fails the deliverable.
- **Process lifecycle correctness.** Six fixes: (1) `cleanup/1` must clean up all Lead worktrees on every exit path (normal completion, abort, Foreman crash, job abort); (2) `handle_lead_completion` must demonitor the Lead, remove from `lead_monitors`, and remove from `leads` map; (3) `fail_deliverable` must remove from `leads` map; (4) `do_abort_lead` must add to `failed_leads` (not `completed_leads`); (5) DOWN handler must check exit reason — `:normal` and `:shutdown` are not crashes; (6) before returning `{:stop, ...}` in `do_fail_job_on_foreman_agent_crash`, demonitor all Leads with `:flush` to prevent spurious DOWN processing during shutdown.
- **Sibling process resilience.** The Foreman must look up RateLimiter and Store by registered name on each use, not cache PIDs at init. Cached PIDs go stale if `one_for_one` restarts a sibling.
- **Cost ceiling gating.** When `cost_ceiling_reached` is true, the Foreman must stop forwarding low-priority Lead messages to the ForemanAgent. On spending approval, send a single consolidated catch-up prompt instead of draining stale queued prompts.
- **`set_foreman_agent` guard.** Must check for existing `foreman_agent_monitor_ref` and demonitor before creating a new monitor. Must not double-monitor.

### v0.9 (2026-03-30)
- Added: ForemanAgent tool `fail_deliverable` — on Lead crash, ForemanAgent decides whether to retry (spawn replacement Lead) or skip (count as failed). Foreman's `all_leads_complete?` check counts completed + failed Leads, not just completed. Resolves issue where Lead crashes left jobs stuck in `:executing`.

### v0.8 (2026-03-30)
- Added: Foreman must monitor the ForemanAgent via `Process.monitor`. On ForemanAgent crash, the Foreman fails the job with full cleanup (worktrees, Leads, site log).

### v0.7 (2026-03-29)
- **Breaking: Split Foreman and Lead into orchestrator + agent process pairs.** The Foreman is no longer "IS the Agent" — it is a pure orchestration gen_statem that owns a separate ForemanAgent (a standard Deft.Agent). Same split for Leads. Eliminates the 24-state tuple-state design. Runners remain Tasks.
- Added `:asking` phase before `:planning` — ForemanAgent asks clarifying questions before any research or planning begins
- Removed recursive orchestrator pattern (considered and rejected — adds relay chains, reimplements supervision, breaks OTP idioms)
- Direct PID communication everywhere — no message relay chains
- Agents are reusable Deft.Agent instances with no orchestration knowledge

### v0.6 (2026-03-19)
- Changed: User corrections are now explicit via the `/correct` command. The implicit correction classification via LLM analysis is removed. The Foreman receives `{:lead_message, :correction, ...}` only when users explicitly invoke `/correct`.

### v0.5 (2026-03-19)
- Clarified: Foreman must delegate tool execution to `Deft.Tool.execute/3`, not return placeholder results
- Clarified: Lead state_enter handlers must not use `next_event` actions (prohibited by OTP gen_statem)
- Clarified: Foreman and Lead must call `RateLimiter.reconcile/4` after each LLM response to credit back unused tokens

### v0.4 (2026-03-19)
- Clarified section 4.2: "runs compile checks" means the Lead spawns a testing Runner to verify build and test output — the Lead does not have direct bash access.

### v0.3 (2026-03-17)
- Split rate limiter and git strategy into separate specs.

### v0.2 (2026-03-17)
- **Site Log → OTP messages + Deft.Store.** Replaced the SiteLog GenServer with direct OTP message passing for Foreman↔Lead coordination. Persistent job knowledge lives in a `Deft.Store` site log instance (ETS+DETS).
- Updated job persistence paths to `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/`

### v0.1 (2026-03-16)
- Initial spec — Foreman/Lead/Runner hierarchy with deliverable-level decomposition, dependency DAG with partial unblocking via interface contracts, Site Log coordination, git worktrees per Lead, centralized rate limiter, inline Runner loops

## Overview

Orchestration is Deft's system for breaking complex tasks into parallel work streams executed by a hierarchy of agents. The **Foreman** orchestrates the job — planning, dispatching, steering — while delegating all LLM reasoning to a dedicated **ForemanAgent**. **Leads** manage deliverables, each paired with their own **LeadAgent**. **Runners** execute individual tasks as lightweight Tasks.

The v0.7 redesign splits each role into two processes: an **orchestrator** (gen_statem managing lifecycle, coordination, and process management) and an **agent** (a standard `Deft.Agent` doing LLM reasoning). This eliminates the previous tuple-state design where orchestration phases were multiplied with agent states, producing a 24-state explosion in a single process.

**Scope:**
- Job lifecycle (start, plan, execute, verify, complete)
- Foreman and Lead process pairs (orchestrator + agent)
- Runner role and behavior
- OTP message passing for Foreman↔Lead coordination
- Deft.Store site log for persistent job knowledge
- Interface contracts for cross-deliverable dependencies
- User interaction with the Foreman during execution

**Out of scope:**
- Git worktree strategy (see [git-strategy.md](git-strategy.md))
- Rate limiting and cost tracking (see [rate-limiter.md](rate-limiter.md))
- The agent loop, tools, and provider layer (see [harness.md](harness.md))
- Observational memory internals (see [observational-memory.md](observational-memory.md))
- Cross-job memory, distributed execution, tool permission system

**Dependencies:**
- [harness.md](harness.md) — `Deft.Agent` gen_statem, tools, provider layer, session persistence
- [observational-memory.md](observational-memory.md) — per-agent context management
- [filesystem.md](filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [rate-limiter.md](rate-limiter.md) — centralized rate limiting for LLM calls
- [git-strategy.md](git-strategy.md) — worktree strategy for parallel Lead execution

**Design principles:**
- **Separation of concerns.** Orchestration logic and LLM reasoning live in separate processes. The orchestrator manages lifecycle; the agent thinks.
- **Flat hierarchy, direct communication.** No message relay chains. Processes communicate via direct PID. Use real OTP Supervisors for supervision.
- **Agents are standard Deft.Agent instances.** The ForemanAgent and LeadAgents are regular `Deft.Agent` gen_statem processes as defined in [harness.md](harness.md). No special subclassing.
- **Deliverable-level decomposition.** The Foreman plans big, coherent chunks of work — not individual implementation steps.
- **Leads are the brains.** Leads own their deliverable end-to-end: decompose, steer, course-correct, refine.
- **Runners are lightweight.** Short-lived inline loops. No OM, no persistent state, no supervision tree.
- **Partial unblocking.** A Lead starts as soon as the specific information it needs (interface contract) is available — not when the entire upstream deliverable is done.

## Specification

### 1. Process Architecture

A Job runs as a supervised process tree:

```
Deft.Job.Supervisor (one_for_one)
├── Deft.Store (GenServer — site log instance, ETS+DETS)
├── Deft.Job.RateLimiter (GenServer — see rate-limiter.md)
├── Deft.Job.Foreman (gen_statem — orchestration only, no LLM loop)
│   └── has NO agent loop — delegates to ForemanAgent
├── Deft.Job.ForemanAgent (Deft.Agent gen_statem — standard agent, has OM)
│   └── Deft.Agent.ToolRunner (Task.Supervisor — Foreman's tool execution)
└── Deft.Job.LeadSupervisor (DynamicSupervisor)
    └── per-Lead:
        Deft.Job.Lead.Supervisor (one_for_one)
        ├── Deft.Job.Lead (gen_statem — orchestration only, no LLM loop)
        ├── Deft.Job.LeadAgent (Deft.Agent gen_statem — standard agent, has OM)
        │   └── Deft.Agent.ToolRunner (Task.Supervisor — Lead's tool execution)
        └── Deft.Job.RunnerSupervisor (Task.Supervisor)
            └── Runners (Tasks — inline agent loops, NO OM)
```

Key invariants:
- The Foreman is a `gen_statem` with **only orchestration states** (7 job phases). It does not run an LLM loop.
- The ForemanAgent is a standard `Deft.Agent` as defined in [harness.md](harness.md). It has 4 agent states (`:idle`, `:calling`, `:streaming`, `:executing_tools`), OM, and a ToolRunner. It knows nothing about orchestration.
- The Foreman sends prompts to the ForemanAgent and receives structured results. The ForemanAgent's tools include orchestration-specific tools (e.g., `request_research`, `submit_plan`, `unblock_lead`) that send messages back to the Foreman.
- Leads follow the same pattern: Lead (orchestrator) + LeadAgent (standard Deft.Agent).
- Runners are Tasks spawned via `Task.Supervisor.async_nolink`. Simple inline loops. Leads must enforce Runner timeouts manually.
- Lead gen_statem child specs use `restart: :temporary` — the Foreman handles Lead crash recovery explicitly.
- The Foreman monitors all Leads and the ForemanAgent via `Process.monitor`. On ForemanAgent crash, the Foreman fails the job with cleanup. Leads monitor their Runners via Task refs. The DOWN handler must check exit reason: only unexpected reasons trigger crash recovery. `:normal` and `:shutdown` exits are not crashes.
- All LLM calls flow through `Deft.Job.RateLimiter` (see [rate-limiter.md](rate-limiter.md)).
- The Foreman looks up RateLimiter and Store by registered name on each use. It must NOT cache PIDs at init — sibling processes may restart under `one_for_one`, making cached PIDs stale. The same applies to ForemanAgent: the Foreman must use the ForemanAgent's registered name (via-tuple) for all `Deft.Agent.prompt/2` calls, not resolve to a raw PID. The monitor ref is separate from the communication path.
- The Foreman must monitor Store and RateLimiter via `Process.monitor` at init. Since both use `restart: :temporary`, they are never restarted by the supervisor. On Store or RateLimiter crash (`:DOWN` message), the Foreman must fail the job with cleanup — these are unrecoverable infrastructure failures.
- All Foreman↔Lead communication is via direct OTP messages between the Foreman and Lead orchestrator processes.

### 2. Foreman↔ForemanAgent Interface

The Foreman communicates with its agent through two mechanisms:

**Foreman → ForemanAgent:** The Foreman sends prompts to the ForemanAgent via `Deft.Agent.prompt/2`. The prompt includes the current job context — research results, Lead progress, contracts received, user messages.

**ForemanAgent → Foreman:** The ForemanAgent has orchestration tools in its tool set that, when called, send messages to the Foreman process:

| Tool | Message to Foreman | Purpose |
|------|-------------------|---------|
| `ready_to_plan` | `{:agent_action, :ready_to_plan}` | Signal that Q&A is complete, transition to `:planning` |
| `request_research` | `{:agent_action, :research, topics}` | Fan out research to Runners |
| `submit_plan` | `{:agent_action, :plan, deliverables}` | Present decomposition for approval |
| `spawn_lead` | `{:agent_action, :spawn_lead, deliverable}` | Start a Lead for a deliverable. On retry (deliverable already has an outcome from auto-fail), must clear `deliverable_outcomes` for that deliverable before spawning. |
| `unblock_lead` | `{:agent_action, :unblock_lead, lead_id, contract}` | Manually unblock a Lead (override only — see section 4.4 for auto-unblocking) |
| `steer_lead` | `{:agent_action, :steer_lead, lead_id, content}` | Send course correction to a Lead |
| `abort_lead` | `{:agent_action, :abort_lead, lead_id}` | Stop a Lead |
| `fail_deliverable` | `{:agent_action, :fail_deliverable, lead_id}` | Mark a Lead's deliverable as failed (after crash or unrecoverable blocker). Lead is removed, marked as failed. Foreman's `all_leads_complete?` checks that every deliverable has a final outcome (completed or failed), not a lead count. |

These tools are implemented as thin wrappers that `send(foreman_pid, message)` and return `:ok` to the agent. The Foreman receives these in `handle_info` and takes action.

The Foreman also sends results back to the ForemanAgent when research completes, Leads report progress, or user input arrives — by calling `Deft.Agent.prompt/2` with the new information.

#### 2.1 Code-Speed vs LLM-Speed Boundary

The Foreman handles **deterministic coordination at code speed** and delegates **strategic decisions to the ForemanAgent**. This distinction matters because the ForemanAgent processes prompts serially — each is an LLM round-trip. Routing every OTP message through the LLM would create serial bottlenecks as Lead count scales.

**Code-speed (Foreman handles directly, notifies ForemanAgent after):**
- Contract matching: published contracts are matched against the plan's dependency DAG and forwarded to blocked Leads immediately (see section 4.4)
- Lead completion bookkeeping: tracking set updates, monitor cleanup, worktree cleanup
- Crash timeout enforcement: auto-fail a crashed Lead's deliverable if ForemanAgent doesn't respond within the configured timeout

**LLM-speed (routed to ForemanAgent as prompts):**
- Steering decisions (steer, abort, retry)
- Plan creation and amendment
- Research synthesis
- Crash triage (retry vs. fail) — but with a timeout fallback

**Lead message coalescing:** Low-priority Lead messages (`:status`, `:artifact`, `:decision`, `:finding`, `:contract`, `:contract_revision`) are buffered in the Foreman's state. High-priority messages (`:blocker`, `:complete`, `:error`, `:critical_finding`) flush the buffer and are forwarded immediately.

The buffer uses a **max-age flush** strategy (not a sliding-window debounce). The Foreman tracks `buffer_start_time` — the timestamp when the first message entered an empty buffer. On each new low-priority message: if `now - buffer_start_time >= debounce_ms` (configurable, default 2s), flush immediately; otherwise, append to the buffer and leave the existing timer running. The timer is set once when the first message arrives and is NOT reset on subsequent messages. This guarantees the ForemanAgent receives consolidated updates every `debounce_ms` under sustained load.

The flush timer handler must also check the `foreman_agent_restarting` flag. When true, the handler must be a no-op — leave the buffer intact so its contents are included in the restart catch-up prompt. The timer may have been set before the ForemanAgent crashed; firing it during the restart window would send to a dead process and lose buffered messages.

`:contract` is low-priority because contract auto-unblocking already happened at code speed (section 4.4). The ForemanAgent notification is informational — it does not need to trigger an immediate prompt.

### 3. Job Lifecycle

The Foreman gen_statem has seven states (no tuple — just job phases):

```
:asking ──▶ :planning ──▶ :researching ──▶ :decomposing ──▶ :executing ──▶ :verifying ──▶ :complete
```

| Phase | Foreman does | ForemanAgent does |
|-------|-------------|-------------------|
| `:asking` | Sends user prompt to ForemanAgent. Relays ForemanAgent questions to user, user answers back to ForemanAgent. Loops until ForemanAgent signals ready. | Analyzes request, asks clarifying questions about scope, constraints, edge cases. Calls `ready_to_plan` tool when satisfied. |
| `:planning` | Transitions on `ready_to_plan`. Sends accumulated context to ForemanAgent. | Analyzes request with full context from Q&A, calls `request_research` tool with topics |
| `:researching` | Spawns research Runners, collects results, sends findings to ForemanAgent | Receives findings, calls `submit_plan` tool with deliverables and DAG |
| `:decomposing` | Receives plan, presents to user for approval, waits | (idle — waiting for approval) |
| `:executing` | Spawns Leads per the plan, monitors progress, handles contracts, relays steering | Receives Lead progress/blockers, calls `steer_lead`/`unblock_lead`/`spawn_lead` as needed |
| `:verifying` | All Leads complete. Spawns verification Runner | (idle — waiting for verification) |
| `:complete` | Squash-merges all work (see [git-strategy.md](git-strategy.md)), reports summary, cleans up | Generates summary for user |

**Single-agent fallback:** If the task is simple enough (touches 1-2 files, no natural decomposition, estimated < 3 Runner tasks), the Foreman skips orchestration — the ForemanAgent executes directly with a full tool set (read, write, edit, bash, grep, find, ls). No Leads are spawned.

**Auto-approve:** The `--auto-approve-all` flag skips all plan approval gates. For `deft work --loop`, this is the only way to skip approvals — each plan is approved by default (see [issues.md](issues.md) section 5.3). For non-interactive mode (`deft -p "prompt"`), `--auto-approve-all` is required since no user is present.

**Startup orphan cleanup:** On launch, Deft scans for orphaned `deft/job-*` branches and `deft/lead-*` worktrees from prior crashed jobs. See [git-strategy.md](git-strategy.md) for details.

### 4. Foreman

The Foreman orchestrates the entire job. It is a gen_statem with **only job phase states** (7 phases) — no agent loop, no streaming, no tool execution.

#### 4.1 Asking Phase

The first thing the Foreman does after receiving a user prompt is enter `:asking`. The ForemanAgent receives the prompt and asks clarifying questions — scope, constraints, edge cases, ambiguities. The Foreman relays the ForemanAgent's questions to the user and the user's answers back to the ForemanAgent. This loop continues until the ForemanAgent calls `ready_to_plan`, which transitions the Foreman to `:planning`.

The ForemanAgent decides when it has enough information. For simple, unambiguous requests it may call `ready_to_plan` immediately without asking anything. For complex or vague requests it should ask until the task is well-defined.

**Auto-approve interaction:** When `--auto-approve-all` is set, the asking phase is skipped entirely — the Foreman transitions directly to `:planning`. The ForemanAgent works with whatever context the prompt provides.

#### 4.2 Research Phase

When the ForemanAgent calls `request_research`, the Foreman spawns research Runners in parallel with read-only tools and the same model as Leads (Sonnet). Runners report findings via Task return value. Configurable timeout (default 120s). Results are sent to the ForemanAgent as a prompt with structured findings.

#### 4.3 Work Decomposition

The ForemanAgent reviews findings and calls `submit_plan` with: deliverables (typically 1-3, rarely >5), a dependency DAG (logical, not file-based), interface contracts for each dependency edge, and cost/duration estimates. The Foreman validates the dependency DAG before accepting the plan: (1) all `:from`/`:to` IDs in dependencies must reference valid deliverable IDs, (2) no self-loops, (3) no cycles (topological sort). If validation fails, the Foreman rejects the plan and prompts the ForemanAgent to fix it. On valid plan, the Foreman writes it to the site log and presents it to the user for approval.

#### 4.4 Partial Dependency Unblocking

Contract unblocking happens at **code speed**. The Foreman receives `{:lead_message, :contract, content, metadata}` messages from Lead orchestrators and immediately matches the contract against the plan's dependency DAG to identify which downstream Leads are waiting. For each match, the Foreman sends `{:foreman_contract, contract}` to the blocked Lead directly — no LLM round-trip.

After auto-forwarding, the Foreman notifies the ForemanAgent with a consolidated update: "Contract X published by Lead A, auto-forwarded to Lead B." The ForemanAgent retains override capability (it can still call `abort_lead` or `steer_lead` if the contract is wrong).

The `unblock_lead` tool remains available for manual overrides — e.g., when the ForemanAgent decides to unblock a Lead with a synthesized contract not published by any other Lead.

#### 4.5 Merge Strategy

Each Lead works in its own git worktree (see [git-strategy.md](git-strategy.md)). When a Lead completes, the Foreman merges the Lead's branch into the job branch, spawning a merge-resolution Runner if conflicts arise. Merge order follows the dependency DAG; independent Leads are merged in completion order.

#### 4.6 Steering and Monitoring

During execution, the Foreman:
- Receives `{:lead_message, type, content, metadata}` messages from Lead orchestrators in `handle_info`
- Coalesces low-priority Lead messages and forwards consolidated prompts to the ForemanAgent (see section 2.1)
- Only forwards Lead messages to the ForemanAgent when in `:executing` state. In other states, Lead messages are logged and discarded.
- Executes `{:agent_action, ...}` messages from the ForemanAgent (steer, unblock, abort)
- Monitors cost via RateLimiter — pauses execution if approaching the ceiling
- When `cost_ceiling_reached` is true, stops forwarding low-priority Lead messages to the ForemanAgent entirely. Buffers them in state. On spending approval, sends a single consolidated catch-up prompt with current state rather than draining stale queued prompts.
- Handles Lead `:DOWN` messages from `Process.monitor`. On Lead crash, notifies ForemanAgent and starts a configurable timeout (default `job.lead_crash_decision_timeout`, 60s). If ForemanAgent does not call `fail_deliverable` or `spawn_lead` within the timeout, the Foreman auto-fails the deliverable.
- Handles ForemanAgent `:DOWN` messages. On ForemanAgent crash, the Foreman attempts **one restart**: start a new ForemanAgent with the session JSONL for conversation continuity, re-establish the monitor, and send a catch-up prompt with current job state (active Leads, pending contracts, deliverable outcomes). If the restart succeeds, the job continues. If the restart fails or the restarted ForemanAgent crashes again, the Foreman fails the job with full cleanup. During the restart window (while in `:executing`), the Foreman continues handling code-speed operations (contract forwarding, completion bookkeeping, crash timeouts) but buffers all messages that would go to the ForemanAgent.
- Handles Store and RateLimiter `:DOWN` messages. These are unrecoverable — fail the job with full cleanup.

#### 4.7 Conflict Resolution

Conflict detection operates at two levels:

**File-overlap detection (code speed):** The Foreman tracks which files each Lead has modified via `:artifact` messages. When a new `:artifact` arrives, the Foreman checks for file path overlap with other active Leads' artifact sets (`MapSet.intersection`). On overlap, the Foreman pauses both affected Leads and sends the conflict to the ForemanAgent for resolution.

**Semantic conflict detection (LLM speed):** `:decision` messages are low-priority and routed to the ForemanAgent via the standard coalescing path. The ForemanAgent reviews decisions from multiple Leads in consolidated prompts and identifies logical conflicts. When the ForemanAgent detects a semantic conflict, it uses `steer_lead` or `abort_lead` to resolve it.

### 5. Lead

A Lead manages one deliverable end-to-end. Like the Foreman, it is split into a Lead orchestrator (gen_statem) and a LeadAgent (standard Deft.Agent with OM).

#### 5.1 Lead↔LeadAgent Interface

Same pattern as Foreman↔ForemanAgent. The Lead sends prompts to its LeadAgent. The LeadAgent has Lead-specific tools:

| Tool | Message to Lead | Purpose |
|------|----------------|---------|
| `spawn_runner` | `{:agent_action, :spawn_runner, type, instructions}` | Start a Runner task |
| `publish_contract` | `{:agent_action, :publish_contract, content}` | Satisfy an interface contract |
| `report_status` | `{:agent_action, :report, type, content}` | Send progress to Foreman |
| `request_help` | `{:agent_action, :blocker, description}` | Escalate to Foreman |

#### 5.2 Lead Orchestrator States

The Lead gen_statem has simpler phases than the Foreman:

```
:planning ──▶ :executing ──▶ :verifying ──▶ :complete
```

| Phase | Lead does | LeadAgent does |
|-------|----------|---------------|
| `:planning` | Sends deliverable assignment + context to LeadAgent | Reads assignment, research findings, contracts from site log. Decomposes into task list. |
| `:executing` | Spawns Runners on request, collects results, sends to LeadAgent | Evaluates Runner output, decides next tasks, calls `spawn_runner` / `publish_contract` / `report_status` |
| `:verifying` | Spawns testing Runner. Queues any incoming `{:foreman_steering, ...}` messages. | (idle — waiting for verification) |
| `:complete` | Checks queued steering first — if steering contradicts the verification result, re-enters `:executing` without notifying the Foreman. Only sends `:complete` to Foreman when no queued steering triggers re-execution. | Generates deliverable summary |

#### 5.3 Active Steering

The LeadAgent is a **pair-programming manager**: plans tasks with rich context, requests Runners with detailed instructions (via `spawn_runner` tool), evaluates Runner output, requests corrective Runners if needed, updates its task list, requests testing Runners to verify compile checks and tests after each implementation Runner, and reports progress to the Foreman (via `report_status` tool). The LeadAgent's own tool set is read-only ([Read, Grep, Find, Ls](tools.md)) plus the Lead-specific tools above.

The Lead orchestrator handles `{:foreman_steering, content}` messages from the Foreman and injects them into the LeadAgent as prompts. Exception: in `:verifying` state, steering is queued (not injected) and applied after verification completes (see §5.2).

#### 5.4 Interface Contract Publishing

When the LeadAgent completes work that satisfies a dependency, it calls the `publish_contract` tool. The Lead orchestrator sends `{:lead_message, :contract, content, metadata}` to the Foreman.

#### 5.5 Worktree Management

Each Lead operates in its own git worktree. The Foreman creates it when the Lead starts, and handles merge and cleanup when the Lead completes. See [git-strategy.md](git-strategy.md) for full details.

#### 5.6 Reporting

The Lead orchestrator sends messages to the Foreman via `send(foreman_pid, {:lead_message, type, content, metadata})`:
- `:status` — progress updates
- `:decision` — implementation choices with rationale
- `:artifact` — files created or modified
- `:contract` / `:contract_revision` — interface definitions
- `:plan_amendment` — "my deliverable also needs X"
- `:complete` — deliverable finished, ready for merge
- `:blocker` — stuck, needs Foreman help
- `:error` — something went wrong
- `:critical_finding` — auto-promoted to site log by Foreman
- `:finding` — forwarded Runner findings (Lead may tag as `shared` for site log promotion)

### 6. Runner

A Runner is a short-lived inline agent loop that executes a single task as a Task under the Lead's RunnerSupervisor. Unchanged from v0.6.

#### 6.1 Inline Loop

Runners run a simple function: build minimal context → call LLM (through RateLimiter) → parse tool calls → execute tools inline with try/catch → loop or return results to Lead via Task return value. No gen_statem, no OM.

Runners do NOT message the Foreman directly. The Lead orchestrator is the intermediary.

#### 6.2 Tool Sets

| Runner type | Tools |
|-------------|-------|
| Research | read, grep, find, ls (read-only) |
| Implementation | read, write, edit, bash, grep, find, ls |
| Testing | read, bash, grep, find, ls (no write/edit) |
| Review | read, grep, find, ls (read-only) |
| Merge resolution | read, write, edit, grep |

#### 6.3 Context from Lead

The Lead orchestrator provides each Runner with task instructions, curated context, and the worktree path. Runners do NOT read the site log directly.

### 7. Coordination Protocol

All Foreman↔Lead communication happens via Erlang process messages between the orchestrator processes.

#### 7.1 Message Format

**Lead → Foreman:** `send(foreman_pid, {:lead_message, type, content, metadata})`
**Foreman → Lead:** `send(lead_pid, {:foreman_steering, content})`

#### 7.2 Message Types

| Type | Direction | Purpose |
|------|-----------|---------|
| `plan` | Foreman→broadcast | Work plan with deliverables and DAG |
| `finding` | Runner→Lead→Foreman | Research result. Lead may tag as `shared` when forwarding to Foreman — shared findings are auto-promoted to site log. |
| `decision` | Lead→Foreman | Choice made with rationale |
| `contract` | Lead→Foreman | Interface definition satisfying a dependency |
| `contract_revision` | Lead→Foreman | Updated contract |
| `artifact` | Lead→Foreman | File created or modified |
| `status` | Lead→Foreman | Progress update |
| `blocker` | Lead→Foreman | Stuck, needs Foreman input |
| `steering` | Foreman→Lead | Guidance |
| `plan_amendment` | Lead→Foreman | Request for plan change |
| `complete` | Lead→Foreman | Deliverable finished |
| `error` | Any→Foreman | Something went wrong |
| `cost` | RateLimiter→Foreman | Cost checkpoint (sent as `{:rate_limiter, :cost, amount}`, not `{:lead_message, ...}`) |
| `correction` | User→Foreman (via `/correct`) | User course-correction via explicit `/correct` command — auto-promoted to site log |
| `critical_finding` | Lead→Foreman | Important finding — auto-promoted to site log |

#### 7.3 Deft.Store Site Log Instance

The Foreman maintains a `Deft.Store` instance (ETS+DETS) for curated job knowledge.

**Write policy:** The Foreman writes based on incoming messages. Auto-promoted types: `contract`, `decision`, `correction`, `critical_finding`. Other types written at the Foreman's discretion.

**Read access:** LeadAgents can read from the site log to access contracts, decisions, and other curated knowledge.

### 8. User Interaction During Jobs

The user interacts with the Foreman through the normal web UI chat interface.

#### 8.1 Status Display

The web UI shows Lead status (running/waiting/complete), current Runner activity, cost, elapsed time, and job phase.

#### 8.2 User Commands During Execution

| Action | How |
|--------|-----|
| Check status | `/status` or ask the Foreman |
| Redirect | "Focus on the backend first" |
| Send correction | `/correct <message>` — explicit course-correction, auto-promoted to site log |
| Abort a deliverable | "Stop working on the frontend" |
| Abort entire job | Ctrl+C or `/abort` (cleans up all worktrees) |
| Add context | "By the way, we use Ecto for the database layer" |
| Modify plan | "Split the backend into API and middleware" |
| Inspect Lead work | `/inspect lead-a` |

User messages arrive at the Foreman orchestrator, which decides whether to forward them to the ForemanAgent as prompts or handle them directly (e.g., `/abort` is handled by the Foreman without LLM involvement).

### 9. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.max_leads` | `5` | Maximum concurrent Leads per job |
| `job.max_runners_per_lead` | `3` | Maximum concurrent Runners per Lead |
| `job.research_timeout` | `120_000` | Timeout for research Runners (ms) |
| `job.runner_timeout` | `300_000` | Timeout for implementation Runners (ms) |
| `job.foreman_model` | `"claude-sonnet-4"` | Model for the ForemanAgent |
| `job.lead_model` | `"claude-sonnet-4"` | Model for LeadAgents |
| `job.runner_model` | `"claude-sonnet-4"` | Model for Runners |
| `job.research_runner_model` | `"claude-sonnet-4"` | Model for research Runners |
| `job.max_duration` | `1_800_000` | Maximum job duration (ms, default 30 min) |
| `job.lead_message_debounce` | `2_000` | Debounce timer for low-priority Lead messages (ms) |
| `job.lead_crash_decision_timeout` | `60_000` | Timeout for ForemanAgent to decide retry/fail after Lead crash (ms) |

Plan approval is controlled by the `--auto-approve-all` CLI flag (see [issues.md](issues.md)). No config key — approval is always explicit.

See [rate-limiter.md](rate-limiter.md) for cost ceiling, concurrency, and rate limiter configuration.
See [git-strategy.md](git-strategy.md) for git-related configuration.

### 10. Job Persistence

Jobs are stored at `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/`:
- `sitelog.dets` — the Deft.Store site log persistence
- `plan.json` — the approved work plan (snapshot for resume)
- `foreman_session.jsonl` — the ForemanAgent's session
- `lead_<id>_session.jsonl` — each LeadAgent's session

On resume, the Foreman reads the site log to reconstruct job knowledge. For coordination state, it reads plan.json. For each incomplete deliverable, it starts a fresh Lead + LeadAgent pair with instructions that account for already-completed work. LeadAgent sessions are NOT restored — fresh LeadAgents are simpler and more reliable.

### 11. Cleanup

The Foreman's `cleanup/1` function runs on **every exit path** — normal completion, failure, abort, and crash (via `terminate/3`). Each step must be wrapped in `try/rescue` so that a failure in one step (e.g., filesystem error during worktree cleanup) does not skip remaining steps. It must handle:

1. **Monitors:** Demonitor all Leads (with `:flush`), the ForemanAgent, Store, and RateLimiter. Prevents spurious DOWN messages during shutdown. This goes first to prevent interference from async messages.
2. **Lead processes:** Stop each Lead's supervisor subtree via `DynamicSupervisor.terminate_child`. This cascades shutdown to all children (Lead, LeadAgent, ToolRunner, RunnerSupervisor) and waits for termination.
3. **Worktrees:** Iterate `data.leads` and call `GitJob.cleanup_lead_worktree` for each Lead that has a worktree. This runs after Lead processes are stopped to avoid racing with Runners still writing to the worktree.
4. **Site log:** Stop the Store process if alive.

On `do_fail_job_on_foreman_agent_crash`: demonitor all Leads with `:flush` **first**, then return `{:stop, ...}` and let `terminate/3` call `cleanup/1`. Do NOT call `cleanup(data)` directly — `terminate/3` already calls it (see v0.12).

On Lead crash (individual): Foreman cleans up that Lead's worktree immediately in `do_handle_lead_crash`.

On Lead abort (`do_abort_lead`): Must stop the Lead's entire supervisor subtree via `DynamicSupervisor.terminate_child(lead_supervisor, lead_child_id)`, which cascades shutdown to the Lead, LeadAgent, ToolRunner, and RunnerSupervisor. Do NOT use `Process.exit(lead_pid, :shutdown)` directly — this kills only the Lead gen_statem, orphaning its siblings. After the supervisor confirms termination, call `GitJob.cleanup_lead_worktree` — the worktree must not be cleaned while Runners may still be writing. Then remove the Lead from `data.leads`.

On Lead normal completion: `handle_lead_completion` demonitors the Lead, removes from `leads` and `lead_monitors`, and cleans up the worktree.

On `fail_deliverable`: Must demonitor the Lead (if still in `lead_monitors`) and clean up the worktree. When called after a crash, `do_handle_lead_crash` already handled both — `fail_deliverable` must check and skip if already done.

Job files at `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/` are archived (not deleted) for debugging.

## Notes

### Design decisions

- **Orchestrator + Agent split over "Foreman IS the Agent".** The v0.1–v0.6 design fused orchestration and agent logic into a single gen_statem, producing 24 possible states (6 phases × 4 agent states) and a 4,300+ line module. Separating them gives each process a single responsibility and makes both independently testable. The tradeoff is coordination across a process boundary, but the interface is narrow (prompts in, tool-as-message out).
- **Flat split over recursive orchestrators.** A recursive "orchestrator at every level" pattern was considered and rejected. It reimplements OTP supervision in GenServers, creates message relay chains that add latency and failure modes, and the "same behaviour everywhere" claim breaks down because each level has distinct domain concerns (DAG management, worktrees, tool execution). One split per role is sufficient.
- **Agent tools as orchestration interface.** The ForemanAgent doesn't call Foreman APIs — it uses tools (`request_research`, `submit_plan`, etc.) that send messages to the Foreman. This keeps the agent a standard Deft.Agent with no special coupling, and the LLM naturally reasons about orchestration actions as tool calls.
- **Deliverable-level decomposition over file-level.** Real work has overlapping files. The dependency DAG handles integration; git worktrees handle file isolation.
- **Partial unblocking over full-chunk dependencies.** More parallelism, same correctness.
- **Research on Sonnet, not Haiku.** Research quality determines plan quality. Marginal cost is negligible.
- **OTP messages over shared files for coordination.** BEAM mailbox semantics provide FIFO ordering and no race conditions.
- **Code-speed orchestration over LLM-mediated everything.** Deterministic coordination (contract DAG matching, completion bookkeeping, crash timeouts) should not require an LLM round-trip. The Foreman handles these at code speed and sends consolidated batches to the ForemanAgent for strategic decisions only. This avoids a design where every Lead message becomes an independent prompt, which would create serial processing bottlenecks as Lead count scales.
- **Registered name lookups over cached PIDs for siblings.** Under `one_for_one`, a sibling restart gives the new process a different PID. Cached PIDs go stale silently. Registry lookups are microsecond-cost and always resolve to the current process.

### Resolved questions

- **Merge conflict resolution quality.** LLMs can reliably resolve git merge conflicts in practice. The merge-resolution Runner handles this without user fallback.
- **Lead-to-Lead communication.** Leads sharing a worktree should be aware of what other Leads in that worktree are doing. The Foreman broadcasts relevant Lead status to co-located Leads so they can coordinate.
- **Compile-check language generality.** Not an issue. Testing Runners are LLM agents — they read `CLAUDE.md` / `AGENTS.md`, discover what build/test commands are available in the project, and run them. No hardcoded language detection needed.
- **Job completion notification.** Displayed in the web UI. No desktop notifications or email — the UI is the notification surface.
- **ForemanAgent tool set in single-agent fallback.** The ForemanAgent is started with the full tool set (read, write, edit, bash, grep, find, ls, plus orchestration tools). In single-agent mode, the ForemanAgent uses file/bash tools directly and ignores orchestration tools. In orchestrated mode, it uses orchestration tools and its own file tools are read-only. The Foreman controls which mode via the initial prompt context.

## References

- [harness.md](harness.md) — Deft.Agent gen_statem, tools, provider layer
- [observational-memory.md](observational-memory.md) — per-agent context management
- [filesystem.md](filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [rate-limiter.md](rate-limiter.md) — centralized rate limiting for LLM calls
- [git-strategy.md](git-strategy.md) — git worktree strategy for parallel Lead execution
