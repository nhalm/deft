# Orchestration

| | |
|--------|----------------------------------------------|
| Version | 0.4 |
| Status | Ready |
| Last Updated | 2026-03-19 |

## Changelog

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

Orchestration is Deft's system for breaking complex tasks into parallel work streams executed by a hierarchy of agents. The **Foreman** plans the work, dispatches research Runners, distills findings into a structured work plan with a dependency DAG, assigns deliverables to Leads, and steers the whole operation to completion. **Leads** manage their deliverables end-to-end, and **Runners** execute individual tasks as lightweight inline loops.

Agents coordinate through **OTP message passing**. Curated job knowledge is persisted in a **Deft.Store** site log instance (ETS+DETS). Each Lead gets its own git worktree (see [git-strategy.md](git-strategy.md)), and all LLM calls flow through a centralized rate limiter (see [rate-limiter.md](rate-limiter.md)).

**Scope:**
- Job lifecycle (start, plan, execute, verify, complete)
- Foreman, Lead, and Runner roles and behavior
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
- [harness.md](harness.md) — agent loop, tools, provider layer, session persistence
- [observational-memory.md](observational-memory.md) — per-agent context management
- [filesystem.md](filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [rate-limiter.md](rate-limiter.md) — centralized rate limiting for LLM calls
- [git-strategy.md](git-strategy.md) — worktree strategy for parallel Lead execution

**Design principles:**
- **Deliverable-level decomposition.** The Foreman plans big, coherent chunks of work — not individual implementation steps.
- **Leads are the brains.** Leads own their deliverable end-to-end: decompose, steer, course-correct, refine.
- **Runners are lightweight.** Short-lived inline loops. No OM, no persistent state, no supervision tree.
- **Dependency DAG, not file ownership.** Work is decomposed by logical concern. Files will overlap. The dependency graph and git worktrees manage integration.
- **Partial unblocking.** A Lead starts as soon as the specific information it needs (interface contract) is available — not when the entire upstream deliverable is done.

## Specification

### 1. Process Architecture

A Job runs as a supervised process tree:

```
Deft.Job.Supervisor (one_for_one)
├── Deft.Store (GenServer — site log instance, ETS+DETS)
├── Deft.Job.RateLimiter (GenServer — see rate-limiter.md)
├── Deft.Job.Foreman (gen_statem — IS the Agent, extended with orchestration states)
│   └── has OM (Foreman is long-lived)
└── Deft.Job.LeadSupervisor (DynamicSupervisor)
    └── per-Lead:
        Deft.Job.Lead.Supervisor (one_for_one)
        ├── Deft.Job.Lead (gen_statem — IS the Agent, extended with chunk management states)
        │   └── has OM (Leads are medium-lived)
        └── Deft.Job.RunnerSupervisor (Task.Supervisor)
            └── Runners (Tasks — inline agent loops, NO OM)
```

**State composition:** The Foreman and Leads use gen_statem with **tuple states**: `{job_phase, agent_state}`. The `handle_event` callback mode allows fallback handlers that fire in any state — critical for the Foreman to handle incoming Lead messages while in any agent state.

Key invariants:
- The Foreman IS a `Deft.Agent` gen_statem extended with orchestration states. Not a separate process wrapping an Agent.
- Leads follow the same pattern — `{chunk_phase, agent_state}` tuple states.
- Runners are Tasks spawned via `Task.Supervisor.async_nolink`. Simple inline loops. Leads must enforce Runner timeouts manually.
- Lead gen_statem child specs use `restart: :temporary` — the Foreman handles Lead crash recovery explicitly.
- The Foreman monitors all Leads via `Process.monitor`. Leads monitor their Runners via Task refs.
- All LLM calls flow through `Deft.Job.RateLimiter` (see [rate-limiter.md](rate-limiter.md)).
- All Foreman↔Lead coordination is via OTP messages. The Deft.Store site log holds curated job knowledge.

### 2. Job Lifecycle

```
:planning ──▶ :researching ──▶ :decomposing ──▶ :executing ──▶ :verifying ──▶ :complete
```

| Phase | Description |
|-------|-------------|
| `:planning` | Foreman receives user prompt. Analyzes the request, determines what research is needed. |
| `:researching` | Foreman spawns research Runners (read-only tools) in parallel. Runners report findings back. |
| `:decomposing` | Foreman distills findings into deliverables with a dependency DAG. Defines interface contracts. Presents plan to user for approval. |
| `:executing` | Foreman spawns Leads in dependency order. Receives progress messages. Partially unblocks dependent Leads as interface contracts are satisfied. |
| `:verifying` | All Leads complete. Foreman spawns a verification Runner (full test suite + review of modified files). |
| `:complete` | Verification passes. Foreman squash-merges all work into main branch (see [git-strategy.md](git-strategy.md)). Reports summary. Cleans up. |

**Single-agent fallback:** If the task is simple enough (touches 1-2 files, no natural decomposition, estimated < 3 Runner tasks), the Foreman skips orchestration and executes directly.

**Auto-approve:** The `--auto-approve-all` flag skips all plan approval gates. For `deft work --loop`, this is the only way to skip approvals — each plan is approved by default (see [issues.md](issues.md) section 5.3). For non-interactive mode (`deft -p "prompt"`), `--auto-approve-all` is required since no user is present.

**Startup orphan cleanup:** On launch, Deft scans for orphaned `deft/job-*` branches and `deft/lead-*` worktrees from prior crashed jobs. See [git-strategy.md](git-strategy.md) for details.

### 3. Foreman

The Foreman orchestrates the entire job. It IS a `Deft.Agent` extended with orchestration states.

#### 3.1 Research Phase

Spawns research Runners in parallel with read-only tools and the same model as Leads (Sonnet — research quality is the foundation of plan quality). Runners report findings via Task return value. Configurable timeout (default 120s).

#### 3.2 Work Decomposition

After research, the Foreman: reviews findings, decomposes into **deliverables** (typically 1-3, rarely >5), builds a **dependency DAG** (logical, not file-based), defines **interface contracts** for each dependency edge, estimates cost/duration, writes the plan to the site log, and presents it to the user for approval.

#### 3.3 Partial Dependency Unblocking

The Foreman receives `{:lead_message, :contract, content, metadata}` messages from Leads that satisfy interface contracts. When a contract is satisfied, the Foreman creates a worktree for the unblocked Lead and starts it with the contract details. This lets Lead B start while Lead A is still finishing — as soon as the API shape is defined.

#### 3.4 Merge Strategy

Each Lead works in its own git worktree (see [git-strategy.md](git-strategy.md)). When a Lead completes, the Foreman merges the Lead's branch into the job branch, spawning a merge-resolution Runner if conflicts arise. Merge order follows the dependency DAG; independent Leads are merged in completion order.

#### 3.5 Steering and Monitoring

During execution, the Foreman:
- Receives `{:lead_message, type, content, metadata}` messages from Leads in `handle_info`
- Sends `{:foreman_steering, content}` messages to Lead processes for course correction
- Watches for `:contract` messages to partially unblock dependent Leads
- Monitors cost via RateLimiter — pauses execution if approaching the ceiling
- Can re-plan: split a deliverable, spawn additional Leads, or reassign work

#### 3.6 Conflict Resolution

If two parallel Leads send conflicting `:decision` messages, the Foreman detects the conflict, pauses affected Leads, decides the resolution (or asks the user), and sends steering messages with the resolved approach.

### 4. Lead

A Lead manages one deliverable end-to-end. It IS a `Deft.Agent` extended with chunk management capabilities. Each Lead has its own OM instance.

#### 4.1 Work Breakdown

When a Lead starts, it reads its deliverable assignment and interface contracts from the site log, reads research findings, and decomposes the deliverable into a task list — a living document refined as Runners complete tasks.

#### 4.2 Active Steering

The Lead is a **pair-programming manager**: plans tasks with rich context, spawns Runners with detailed instructions, evaluates Runner output, spawns corrective Runners if needed, updates its task list, spawns a testing Runner to verify compile checks and tests after each implementation Runner, and sends progress messages to the Foreman. The Lead is the memory bridge — Runners get exactly the context the Lead decides they need. The Lead's own tool set is read-only ([Read, Grep, Find, Ls](tools.md)) — execution and verification tasks are delegated to Runners.

The Lead handles `{:foreman_steering, content}` messages from the Foreman in `handle_info`, allowing course correction at any point.

#### 4.3 Interface Contract Publishing

When a Lead completes work that satisfies a dependency, it sends a `:contract` message to the Foreman, which writes it to the site log and triggers partial unblocking.

#### 4.4 Worktree Management

Each Lead operates in its own git worktree. The Foreman creates it when the Lead starts, and handles merge and cleanup when the Lead completes. See [git-strategy.md](git-strategy.md) for full details.

#### 4.5 Reporting

The Lead sends messages to the Foreman via `send(foreman_pid, {:lead_message, type, content, metadata})`:
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

### 5. Runner

A Runner is a short-lived inline agent loop that executes a single task as a Task under the Lead's RunnerSupervisor.

#### 5.1 Inline Loop

Runners run a simple function: build minimal context → call LLM (through RateLimiter) → parse tool calls → execute tools inline with try/catch → loop or return results to Lead via Task return value. No gen_statem, no OM.

Runners do NOT message the Foreman directly. The Lead is the intermediary.

#### 5.2 Tool Sets

| Runner type | Tools |
|-------------|-------|
| Research | read, grep, find, ls (read-only) |
| Implementation | read, write, edit, bash, grep, find, ls |
| Testing | read, bash, grep, find, ls (no write/edit) |
| Review | read, grep, find, ls (read-only) |
| Merge resolution | read, write, edit, grep |

#### 5.3 Context from Lead

The Lead provides each Runner with task instructions, curated context, and the worktree path. Runners do NOT read the site log directly.

### 6. Coordination Protocol

All Foreman↔Lead communication happens via Erlang process messages.

#### 6.1 Message Format

**Lead → Foreman:** `send(foreman_pid, {:lead_message, type, content, metadata})`
**Foreman → Lead:** `send(lead_pid, {:foreman_steering, content})`

#### 6.2 Message Types

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
| `correction` | User→Foreman | User course-correction — auto-promoted to site log |
| `critical_finding` | Lead→Foreman | Important finding — auto-promoted to site log |

#### 6.3 Deft.Store Site Log Instance

The Foreman maintains a `Deft.Store` instance (ETS+DETS) for curated job knowledge.

**Write policy:** The Foreman writes based on incoming messages. Auto-promoted types: `contract`, `decision`, `correction`, `critical_finding`. Other types written at the Foreman's discretion.

**Read access:** Leads can read from the site log to access contracts, decisions, and other curated knowledge.

### 7. User Interaction During Jobs

The user interacts with the Foreman through the normal TUI chat interface.

#### 7.1 Status Display

The TUI shows Lead status (running/waiting/complete), current Runner activity, cost, elapsed time, and job phase.

#### 7.2 User Commands During Execution

| Action | How |
|--------|-----|
| Check status | `/status` or ask the Foreman |
| Redirect | "Focus on the backend first" |
| Abort a deliverable | "Stop working on the frontend" |
| Abort entire job | Ctrl+C or `/abort` (cleans up all worktrees) |
| Add context | "By the way, we use Ecto for the database layer" |
| Modify plan | "Split the backend into API and middleware" |
| Inspect Lead work | `/inspect lead-a` |

### 8. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.max_leads` | `5` | Maximum concurrent Leads per job |
| `job.max_runners_per_lead` | `3` | Maximum concurrent Runners per Lead |
| `job.research_timeout` | `120_000` | Timeout for research Runners (ms) |
| `job.runner_timeout` | `300_000` | Timeout for implementation Runners (ms) |
| `job.foreman_model` | `"claude-sonnet-4"` | Model for the Foreman |
| `job.lead_model` | `"claude-sonnet-4"` | Model for Leads |
| `job.runner_model` | `"claude-sonnet-4"` | Model for Runners |
| `job.research_runner_model` | `"claude-sonnet-4"` | Model for research Runners |
| `job.max_duration` | `1_800_000` | Maximum job duration (ms, default 30 min) |

Plan approval is controlled by the `--auto-approve-all` CLI flag (see [issues.md](issues.md)). No config key — approval is always explicit.

See [rate-limiter.md](rate-limiter.md) for cost ceiling, concurrency, and rate limiter configuration.
See [git-strategy.md](git-strategy.md) for git-related configuration.

### 9. Job Persistence

Jobs are stored at `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/`:
- `sitelog.dets` — the Deft.Store site log persistence
- `plan.json` — the approved work plan (snapshot for resume)
- `foreman_session.jsonl` — the Foreman's agent session
- `lead_<id>_session.jsonl` — each Lead's agent session

On resume, the Foreman reads the site log to reconstruct job knowledge. For coordination state, it reads plan.json. For each incomplete deliverable, it starts a fresh Lead with instructions that account for already-completed work. Lead sessions are NOT restored — fresh Leads are simpler and more reliable.

### 10. Cleanup

On job completion, failure, or abort:
1. The Foreman cleans up all worktrees (see [git-strategy.md](git-strategy.md) for details)
2. On Lead crash: Foreman cleans up that Lead's worktree immediately
3. Job files at `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/` are archived (not deleted) for debugging

## Notes

### Design decisions

- **Deliverable-level decomposition over file-level.** Real work has overlapping files. The dependency DAG handles integration; git worktrees handle file isolation.
- **Lead as active steering over dispatch-and-wait.** The Lead is the memory bridge and quality gate.
- **Runners as inline loops over full Agent sessions.** Eliminates an entire class of lifecycle management problems.
- **Partial unblocking over full-chunk dependencies.** More parallelism, same correctness.
- **Foreman IS its Agent.** A single gen_statem avoids the two-state-machine deadlock problem.
- **Research on Sonnet, not Haiku.** Research quality determines plan quality. Marginal cost is negligible.
- **OTP messages over shared files for coordination.** BEAM mailbox semantics provide FIFO ordering and no race conditions.

### Open questions

- **Merge conflict resolution quality.** Can an LLM reliably resolve git merge conflicts? Fallback: flag for user.
- **Lead-to-Lead communication.** Is there a need for direct messaging, or is the Foreman always the right intermediary?
- **Compile-check language generality.** Need language-detection and per-language compile/lint commands.
- **Job completion notification.** Desktop notification? Email? Persist results and show on next `deft resume`?

## References

- [harness.md](harness.md) — Deft foundation spec
- [observational-memory.md](observational-memory.md) — per-agent context management
- [filesystem.md](filesystem.md) — Deft.Store details (ETS+DETS persistence)
- [rate-limiter.md](rate-limiter.md) — centralized rate limiting for LLM calls
- [git-strategy.md](git-strategy.md) — git worktree strategy for parallel Lead execution
