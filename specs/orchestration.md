# Orchestration

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Draft |
| Last Updated | 2026-03-16 |

## Changelog

### v0.1 (2026-03-16)
- Initial spec — Foreman/Lead/Runner hierarchy with deliverable-level decomposition, dependency DAG with partial unblocking via interface contracts, Site Log coordination, git worktrees per Lead, centralized rate limiter, inline Runner loops

## Overview

Orchestration is Deft's system for breaking complex tasks into parallel work streams executed by a hierarchy of agents. When a user gives a prompt, the Foreman plans the work, dispatches research Runners to gather context, distills findings into a structured work plan with a dependency DAG, assigns deliverables to Leads, and steers the whole operation to completion.

The design follows a construction-site metaphor: the **Foreman** oversees the job, **Leads** manage their deliverables end-to-end, and **Runners** execute individual tasks. Agents coordinate through a shared **Site Log** — a lightweight append-only JSONL file that serves as the shared memory between all agents in a job.

Each Lead gets its own git worktree, LLM context, and OM instance. Runners are lightweight inline agent loops spawned by Leads — they have no OM, no supervision subtree, and no persistent state. The Lead is the active intelligence that decomposes work, steers Runners, and course-corrects based on results.

**Scope:**
- Job lifecycle (start, plan, execute, verify, complete)
- Foreman: planning deliverables, dependency DAG, Lead assignment, partial unblocking, conflict resolution, steering, merging
- Lead: work breakdown, Runner spawning, active steering, progress monitoring, worktree management, cleanup
- Runner: single-task inline execution, finding reporting
- Site Log: shared append-only JSONL coordination memory
- Interface contracts for cross-chunk dependencies
- Git worktree strategy with merge-based integration
- Centralized rate limiter
- User interaction with the Foreman during execution

**Out of scope:**
- The agent loop, tools, and provider layer (see [harness.md](harness.md))
- Observational memory internals (see [observational-memory.md](observational-memory.md))
- Cross-job memory (each job's Site Log is independent)
- Distributed execution across machines (future)
- Tool permission / approval system (future — no security layer in v0.1)

**Dependencies:**
- [harness.md](harness.md) — agent loop, tools, provider layer, session persistence
- [observational-memory.md](observational-memory.md) — per-agent context management (Foreman and Leads only)

**Design principles:**
- **Deliverable-level decomposition.** The Foreman plans big, coherent chunks of work — not individual implementation steps. "Build the backend auth system" is a deliverable. "Create user migration" is a task for a Lead to assign to a Runner.
- **Leads are the brains.** Leads own their deliverable end-to-end: they decompose, steer, course-correct, and refine their plan as they learn. The Foreman gives direction; the Lead figures out how.
- **Runners are lightweight.** Short-lived inline loops. No OM, no persistent state, no supervision tree. They get exactly the context the Lead gives them and nothing more.
- **Dependency DAG, not file ownership.** Work is decomposed by logical concern, not by which files each chunk touches. Files will overlap. The dependency graph and git worktrees manage the integration.
- **Partial unblocking.** A Lead doesn't wait for the entire upstream deliverable — it starts as soon as the specific information it needs (interface contract) is posted to the Site Log.

## Specification

### 1. Process Architecture

A Job runs as a supervised process tree:

```
Deft.Job.Supervisor (one_for_one)
├── Deft.Job.SiteLog (GenServer — owns the JSONL; ETS table for reads)
├── Deft.Job.RateLimiter (GenServer — token-bucket rate limiting for all LLM calls)
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

**State composition:** The Foreman and Leads use gen_statem with **tuple states**: `{job_phase, agent_state}`. For example, `{:executing, :idle}` means the job is executing and the Foreman's agent loop is idle (waiting for user input or events). `{:researching, :streaming}` means research is active and the Foreman is streaming an LLM response. The `handle_event` callback mode (not `state_functions`) allows fallback handlers that fire in any state — critical for the Foreman to handle Site Log events while in any agent state.

Key invariants:
- The Foreman IS a `Deft.Agent` gen_statem extended with orchestration states via tuple states `{job_phase, agent_state}`. Not a separate process wrapping an Agent — a single process with both capabilities. This avoids the two-state-machine deadlock problem.
- Leads follow the same pattern — `{chunk_phase, agent_state}` tuple states.
- Runners are Tasks spawned via `Task.Supervisor.async_nolink`. Each Runner runs a simple inline loop: `prompt → LLM → tool calls → prompt → ... → done`. No gen_statem, no OM processes, no supervision subtree. Leads must enforce Runner timeouts manually (e.g., `Process.send_after` + `Task.Supervisor.terminate_child`) since `async_nolink` does not auto-timeout.
- Lead gen_statem child specs use `restart: :temporary` — the Lead.Supervisor does NOT auto-restart crashed Leads. The Foreman handles Lead crash recovery explicitly (fresh Lead with Site Log summary). This prevents the Supervisor and Foreman from both trying to restart.
- The Foreman monitors all Leads via `Process.monitor`. Leads monitor their Runners via Task refs.
- All LLM calls flow through `Deft.Job.RateLimiter` which enforces per-provider rate limits.
- The SiteLog GenServer owns writes (append to JSONL + ETS insert). Reads go directly to ETS, bypassing the GenServer for performance.

### 2. Job Lifecycle

```
:planning ──▶ :researching ──▶ :decomposing ──▶ :executing ──▶ :verifying ──▶ :complete
```

| Phase | Description |
|-------|-------------|
| `:planning` | Foreman receives user prompt. Analyzes the request, determines what research is needed. |
| `:researching` | Foreman spawns research Runners (read-only tools) in parallel. Runners report findings to Site Log. |
| `:decomposing` | Foreman distills findings into deliverables with a dependency DAG. Defines interface contracts for cross-deliverable dependencies. Presents plan to user for approval. |
| `:executing` | Foreman spawns Leads (one per deliverable) in dependency order. Creates worktrees. Monitors progress via Site Log. Partially unblocks dependent Leads as interface contracts are satisfied. Resolves conflicts at merge time. |
| `:verifying` | All Leads complete. Foreman spawns a verification Runner that runs the full test suite (`mix test` or equivalent) and reviews all modified files for consistency. |
| `:complete` | Verification passes. Foreman squash-merges all work into main branch. Reports summary to user. Cleans up job worktrees. |

**Single-agent fallback:** If the Foreman determines the task is simple enough for a single agent (touches 1-2 files, no natural decomposition, estimated < 3 Runner tasks), it skips orchestration and executes directly as a regular Agent session. No Leads, no worktrees, no Site Log overhead.

**Auto-approve:** In non-interactive mode (`deft -p "prompt"`), plan approval blocks forever with no user present. The `--auto-approve` flag (or `job.auto_approve: true` config) skips the approval gate. A cost-threshold variant is also supported: `job.auto_approve_under: 5.00` auto-approves if estimated cost is under $5.

**Startup orphan cleanup:** On launch, Deft scans for orphaned `deft/job-*` branches and `deft/lead-*` worktrees from prior crashed jobs. If found, offers to clean them up (interactive) or cleans automatically (non-interactive with `--auto-approve`).

### 3. Foreman

The Foreman orchestrates the entire job. It IS a `Deft.Agent` extended with orchestration states.

#### 3.1 Research Phase

The Foreman spawns research Runners in parallel. Research Runners use read-only tools (read, grep, find, ls) and the same model as Leads (Sonnet — research quality is the foundation of plan quality).

Research Runners write `finding` entries to the Site Log. The Foreman waits for all to complete (configurable timeout, default: 120 seconds).

#### 3.2 Work Decomposition

After research, the Foreman:

1. Reads all `finding` entries from the Site Log
2. Decomposes the task into **deliverables** — big, coherent chunks of work. Typical jobs have **1-3 deliverables**, rarely more than 5.
3. Builds a **dependency DAG** between deliverables. Dependencies are logical ("frontend auth needs the API contract from backend auth"), not file-based.
4. For each dependency edge, defines an **interface contract**: what information the downstream Lead needs from the upstream Lead (API shapes, data structures, function signatures, configuration).
5. Estimates cost and duration.
6. Writes the plan to the Site Log as a `plan` entry.
7. Presents the plan to the user:

```
Plan: Build auth system with frontend and backend

Deliverables:
  1. Backend auth (Lead A) — user model, JWT, middleware, endpoints, tests
  2. Frontend auth (Lead B) — login form, token storage, protected routes
     └── depends on: API contract from Lead A

Estimated: 2 leads, ~8 runner tasks, $3-5, ~8 minutes
Parallel lanes: Lead A starts immediately, Lead B starts when API contract is posted

[Approve / Modify / Reject]
```

#### 3.3 Partial Dependency Unblocking

Dependencies are not binary. The Foreman watches the Site Log for entries that satisfy specific interface contracts:

```json
{
  "deliverable": "frontend-auth",
  "lead": "lead-b",
  "depends_on": [
    {
      "deliverable": "backend-auth",
      "needs": "API endpoint shapes (routes, request/response formats)",
      "satisfied_by_type": "contract",
      "satisfied": false
    }
  ]
}
```

When a Lead posts a `contract` entry that matches a dependency, the Foreman:
1. Creates a worktree for the unblocked Lead (branching from main + any already-merged Lead work)
2. Posts a `steering` entry to the unblocked Lead with the contract details
3. Starts the Lead

This means Lead B can start while Lead A is still finishing its remaining tasks — as soon as the API shape is defined, not when all backend auth work is done.

#### 3.4 Merge Strategy

Each Lead works in its own git worktree. When a Lead reports `:complete`:

1. The Foreman merges the Lead's worktree into main.
2. If there are merge conflicts (because a parallel Lead also touched the same files), the Foreman spawns a merge-resolution Runner that reads both versions and produces the merged result.
3. After merging, the Lead's worktree is cleaned up (deleted).
4. Any dependent Leads that start after this merge get the merged base.

Merge order follows the dependency DAG. Independent Leads that ran in parallel are merged in completion order.

#### 3.5 Steering and Monitoring

During execution, the Foreman:
- Reads Lead `status`, `decision`, `blocker`, and `plan_amendment` entries from the Site Log
- Posts `steering` entries when Leads need course correction
- Watches for `contract` entries to partially unblock dependent Leads
- Monitors cost via RateLimiter — pauses execution if approaching the ceiling
- Can re-plan: split a deliverable, spawn additional Leads, or reassign work

#### 3.6 Conflict Resolution

If two parallel Leads post conflicting `decision` entries (e.g., different data formats for the same concept), the Foreman:
1. Detects the conflict by reading decisions
2. Pauses the affected Leads via `steering` entries
3. Decides the resolution (or asks the user)
4. Posts a `steering` entry with the resolved approach
5. Unpauses the Leads

### 4. Lead

A Lead manages one deliverable end-to-end. It IS a `Deft.Agent` extended with chunk management capabilities. Each Lead has its own OM instance.

#### 4.1 Work Breakdown

When a Lead starts, it:
1. Reads its deliverable assignment and any interface contracts from the Site Log
2. Reads relevant `finding` entries from the research phase
3. Decomposes the deliverable into a **task list** — specific, concrete tasks for Runners
4. This task list is a living document — the Lead refines it as Runners complete tasks and the Lead learns more about the codebase

#### 4.2 Active Steering

The Lead doesn't just dispatch Runners and wait. It is a **pair-programming manager**:

1. Plans the next task, injects rich context from its own understanding + Site Log + previous Runner results
2. Spawns a Runner with detailed instructions
3. Reads the Runner's output (Site Log entries + files on disk)
4. Evaluates: Is this correct? Does it match expectations?
5. If wrong → spawns a corrective Runner with guidance about what went wrong
6. If right → updates its task list, plans the next task
7. After each Runner, runs `mix compile --warnings-as-errors` (or equivalent) to catch errors early
8. Posts `status`, `decision`, and `artifact` entries to the Site Log as work progresses

The Lead is the memory bridge for its Runners. It holds the full picture of its deliverable in its own OM-backed context. Runners get exactly the context the Lead decides they need — no more, no less.

#### 4.3 Interface Contract Publishing

When a Lead completes work that satisfies a dependency for another Lead, it posts a `contract` entry to the Site Log:

```json
{
  "type": "contract",
  "agent_id": "lead-a",
  "content": "Auth API contract: POST /auth/register {email, password} → 201 {token, user}; POST /auth/login {email, password} → 200 {token, user}; GET /auth/me (Bearer token) → 200 {user}",
  "metadata": {"deliverable": "backend-auth", "satisfies": "api-contract"}
}
```

The Foreman watches for these and triggers partial unblocking.

#### 4.4 Worktree Management

Each Lead operates in its own git worktree:
- Created by the Foreman when the Lead starts
- Branched from main + any already-merged work from completed Leads
- The Lead's Runners read and write files in this worktree
- Leads commit their work within the worktree as they progress
- When the Lead reports `:complete`, the **Foreman** handles merge and cleanup (not the Lead — avoids race between merge-complete message and Lead death):
  1. Foreman merges the Lead's branch into `deft/job-<job_id>`
  2. **Foreman runs tests on the merged job branch** (`mix test` or equivalent) to catch semantic conflicts early — not just at final verification
  3. If merge or tests fail, Foreman spawns a fix-up Runner or flags for user
  4. On success, Foreman cleans up the worktree (`git worktree remove`)
  5. Lead process terminates

#### 4.5 Reporting

The Lead writes to the Site Log:
- `status` — progress updates
- `decision` — implementation choices with rationale
- `artifact` — files created or modified (with paths)
- `contract` — interface definitions that satisfy dependencies for other Leads
- `plan_amendment` — "my deliverable also needs X that wasn't in the plan"
- `complete` — deliverable finished, ready for merge
- `blocker` — stuck, needs Foreman help

### 5. Runner

A Runner is a short-lived inline agent loop that executes a single task. It runs as a Task under the Lead's RunnerSupervisor.

#### 5.1 Inline Loop

Runners do NOT create a full `Deft.Agent` session. They run a simple function:

```
Deft.Job.Runner.run(task_instructions, tool_set, site_log, config) ->
  1. Build a minimal context: system prompt + task instructions + relevant Site Log context
  2. Call LLM via provider (through RateLimiter)
  3. Parse response for tool calls
  4. Execute tool calls (inline, with try/catch)
  5. If more work needed, loop to step 2
  6. Write results to Site Log (finding, artifact, status entries)
  7. Return results to Lead
```

No gen_statem. No OM. No ToolRunner Task.Supervisor. Tool calls execute inline in the Task process with exception handling. This keeps Runners lightweight — they are the Lead's hands, not independent agents.

#### 5.2 Tool Sets

Runners receive a tool set based on their task:

| Runner type | Tools |
|-------------|-------|
| Research | read, grep, find, ls (read-only) |
| Implementation | read, write, edit, bash, grep, find, ls |
| Testing | read, bash, grep, find, ls (no write/edit) |
| Review | read, grep, find, ls (read-only) |
| Merge resolution | read, write, edit, grep (resolves conflicts) |

#### 5.3 Context from Lead

The Lead provides each Runner with:
- Task instructions (what to do, expected outcome)
- Relevant Site Log entries (filtered by the Lead)
- Key context from the Lead's own understanding (architectural decisions, file state, prior Runner results)
- The worktree path to operate in

Runners do NOT read the full Site Log themselves. The Lead curates what each Runner sees.

### 6. Site Log

The Site Log is the shared coordination memory for all agents in a job.

#### 6.1 Format

A JSONL file at `~/.deft/jobs/<job_id>/site_log.jsonl`. Each line is a JSON object:

```json
{
  "ts": "2026-03-16T22:30:00Z",
  "agent_id": "lead-a",
  "agent_role": "lead",
  "type": "decision",
  "content": "Will use argon2 for password hashing based on OWASP recommendation",
  "metadata": {"deliverable": "backend-auth"}
}
```

#### 6.2 Entry Types

| Type | Who writes | Purpose |
|------|-----------|---------|
| `plan` | Foreman | Deliverables, dependency DAG, interface contract definitions, cost estimate |
| `finding` | Runner, Foreman | Research result, fact discovered about the codebase |
| `decision` | Foreman, Lead | Choice made with rationale |
| `contract` | Lead | Interface definition that satisfies a dependency. Includes a `version` field (integer, starts at 1). |
| `contract_revision` | Lead | Updated contract — incremented version. Foreman must re-steer any downstream Leads already building against the old version. |
| `artifact` | Runner | File created or modified (includes path) |
| `status` | Lead, Runner | Progress update |
| `blocker` | Lead | Stuck, needs Foreman input |
| `steering` | Foreman, Lead | Guidance sent to a subordinate (includes `to` field) |
| `plan_amendment` | Lead | "My deliverable also needs X" — request for plan change |
| `complete` | Lead, Foreman | Deliverable or entire job finished |
| `error` | Any | Something went wrong |
| `cost` | RateLimiter | Periodic cost checkpoint |

#### 6.3 Implementation

The SiteLog GenServer owns the JSONL file and an ETS table:
- **Writes** go through the GenServer (serialized to JSONL file + ETS insert). Uses `handle_continue` for file I/O so callers aren't blocked on disk writes.
- **Reads** go directly to the ETS table, bypassing the GenServer. This eliminates the serialization bottleneck for the most frequent operation.
- The ETS table uses `:bag` mode with entries keyed by `{type, agent_id}` for efficient filtered queries.
- **On GenServer restart** (crash recovery): `init/1` rebuilds the ETS table by replaying the JSONL file. The JSONL is the source of truth; ETS is a read cache. Ordering guarantee: since all writes and reads are serialized through the GenServer (writes) and ETS (reads with atomic inserts), a read that follows a write in wall-clock time is guaranteed to see the write.

#### 6.4 Lifecycle

- Created when a Job starts
- Archived to `~/.deft/jobs/<job_id>/` when the job completes
- Not shared across jobs
- Human-readable — users can `cat` or `jq` the file to understand what happened

### 7. Rate Limiter

`Deft.Job.RateLimiter` is a GenServer that all LLM calls flow through.

**Dual token-bucket algorithm per provider:**
- **RPM bucket** — requests per minute (refills at provider's RPM limit)
- **TPM bucket** — tokens per minute (refills at provider's TPM limit). Deducts estimated input tokens on send (chars/4), reconciles actual usage from response.

**Priority queue:** Foreman > Runner > Lead. Runners are prioritized over Leads because Leads are blocked on their Runners — starving Runners starves Leads (priority inversion).

**Starvation protection:** Lower-priority calls are promoted after waiting 10 seconds. No call waits indefinitely.

**429 handling:** On rate limit error, parse `Retry-After` header if present. Reduce bucket capacity by 20%. Exponential backoff on the specific call. Restore capacity gradually after 60 seconds without 429s.

**Adaptive concurrency:**
- Starts at `job.initial_concurrency` (default 2) concurrent Lead slots
- **Scale-up signal:** Token bucket above 60% capacity for 30+ seconds with zero queued calls → add 1 Lead slot (up to `max_leads`)
- **Scale-down signal:** 429 rate exceeds 2 per minute → remove 1 Lead slot (minimum 1)
- Controls how many Leads the Foreman starts, not individual LLM call slots

**Cost tracking:** Reads `usage` (input_tokens, output_tokens) from API responses. Multiplies by per-model pricing (configurable pricing table). Emits `cost` entries to Site Log every $0.50 increment. Pauses job at `cost_ceiling - $1.00` buffer to absorb in-flight overruns. In-flight calls complete (slight overshoot accepted); no new calls dispatched until user approves.

### 8. Git Strategy

#### 8.1 Job Start

1. Verify the working tree is clean. If there are uncommitted changes, warn the user and ask to stash.
2. Create a job branch from current HEAD: `deft/job-<job_id>`

#### 8.2 Lead Worktrees

1. Foreman creates a worktree for each Lead: `git worktree add <path> -b deft/lead-<id>`
2. The worktree branches from `deft/job-<job_id>` + any already-merged Lead work
3. Runners operate in the Lead's worktree directory
4. Leads commit their work within the worktree as they progress (per-task or per-milestone commits)

#### 8.3 Merge

1. When a Lead reports `:complete`, the Foreman merges the Lead's branch into `deft/job-<job_id>`
2. If merge conflicts occur, the Foreman spawns a merge-resolution Runner
3. After successful merge, the Lead cleans up its worktree (`git worktree remove`)

#### 8.4 Job Complete

1. After verification passes, the Foreman squash-merges `deft/job-<job_id>` into the original branch
2. The user sees a single commit (or can choose to keep individual commits)
3. The job branch is deleted

#### 8.5 Job Failure / Abort

1. If the job is aborted or fails, all Lead worktrees are cleaned up
2. The job branch is deleted (or kept for debugging, configurable)
3. The original branch is untouched — no partial work leaks

### 9. User Interaction During Jobs

The user interacts with the Foreman through the normal TUI chat interface.

#### 9.1 Status Display

```
┌─ Deft ──────────────────────── Job: add auth system ────────┐
│                                                              │
│  Foreman: Plan approved. Starting execution.                 │
│                                                              │
│  Lead A [backend-auth]: ◉ running (task 3/5)                 │
│    → Runner: implementing JWT verification                   │
│  Lead B [frontend-auth]: ◎ waiting (needs API contract)      │
│                                                              │
│  $1.24 spent │ 2 leads │ 4m elapsed │ ◉ executing           │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ > _                                                          │
├──────────────────────────────────────────────────────────────┤
│ 12.4k/200k │ memory: 3.2k/40k │ $1.24/$10 │ ◉ executing   │
└──────────────────────────────────────────────────────────────┘
```

#### 9.2 User Commands During Execution

| Action | How |
|--------|-----|
| Check status | `/status` or ask the Foreman |
| Redirect | "Focus on the backend first" |
| Abort a deliverable | "Stop working on the frontend" |
| Abort entire job | Ctrl+C or `/abort` (cleans up all worktrees) |
| Add context | "By the way, we use Ecto for the database layer" |
| Modify plan | "Split the backend into API and middleware" |
| Inspect Lead work | `/inspect lead-a` (shows Site Log entries for that Lead) |

### 10. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.max_leads` | `5` | Maximum concurrent Leads per job |
| `job.max_runners_per_lead` | `3` | Maximum concurrent Runners per Lead |
| `job.research_timeout` | `120_000` | Timeout for research Runners (ms) |
| `job.runner_timeout` | `300_000` | Timeout for implementation Runners (ms) |
| `job.foreman_model` | `"claude-sonnet-4"` | Model for the Foreman |
| `job.lead_model` | `"claude-sonnet-4"` | Model for Leads |
| `job.runner_model` | `"claude-sonnet-4"` | Model for Runners |
| `job.research_runner_model` | `"claude-sonnet-4"` | Model for research Runners (Sonnet — research quality matters) |
| `job.cost_ceiling` | `10.00` | Job pauses and asks user approval before exceeding ($) |
| `job.cost_warning` | `5.00` | Display warning in TUI when reached ($) |
| `job.initial_concurrency` | `2` | Starting number of concurrent Leads (adaptive scaling) |
| `job.max_duration` | `1_800_000` | Maximum job duration (ms, default 30 min) |
| `job.auto_approve` | `false` | Skip plan approval (for non-interactive mode) |
| `job.auto_approve_under` | `nil` | Auto-approve if estimated cost under this amount ($) |

### 11. Job Persistence

Jobs are stored at `~/.deft/jobs/<job_id>/`:
- `site_log.jsonl` — the Site Log
- `plan.json` — the approved work plan (snapshot for resume)
- `foreman_session.jsonl` — the Foreman's agent session
- `lead_<id>_session.jsonl` — each Lead's agent session

On resume, the Foreman reads the Site Log to reconstruct job state. For each incomplete deliverable, it starts a fresh Lead with instructions that account for already-completed work (based on `artifact` and `status` entries). Lead sessions are NOT restored — fresh Leads are simpler and more reliable.

### 12. Cleanup

On job completion, failure, or abort:
1. The Foreman cleans up all worktrees (`git worktree remove <path>` for each)
2. The Foreman verifies no worktrees remain: `git worktree list` should show only the main working tree
3. On Lead crash: Foreman cleans up that Lead's worktree immediately (Lead is `restart: :temporary`, won't auto-restart)
4. On successful completion, the job branch is deleted after squash-merge
5. On failure/abort, the job branch is deleted (configurable: `job.keep_failed_branches: false`)
6. Job files at `~/.deft/jobs/<job_id>/` are archived (not deleted) for debugging

## Notes

### Design decisions

- **Deliverable-level decomposition over file-level.** Real work has overlapping files. Splitting by files is too rigid and produces over-decomposed plans (5+ Leads for work that's naturally one or two deliverables). The dependency DAG handles integration; git worktrees handle file isolation.
- **Lead as active steering over dispatch-and-wait.** The Lead is the memory bridge and quality gate. It reads Runner output, evaluates correctness, and steers the next task. This produces better results than giving Runners OM and hoping they figure it out independently.
- **Runners as inline loops over full Agent sessions.** A Task cannot own a supervision subtree. Runners making 3-10 LLM calls don't need gen_statem, OM, or a ToolRunner. An inline loop with try/catch is sufficient and eliminates an entire class of lifecycle management problems.
- **Partial unblocking over full-chunk dependencies.** "Lead B depends on Lead A" is too coarse. "Lead B needs the API contract from Lead A" lets B start as soon as that contract is posted, even while A is still working. More parallelism, same correctness.
- **Git worktrees over file ownership.** File ownership prevents Leads from doing their job when the work naturally crosses file boundaries. Worktrees provide true isolation — each Lead has its own copy of the codebase. Conflicts are resolved at merge time, which is the correct place to handle them.
- **Foreman IS its Agent.** Separating the Foreman from its Agent creates two state machines that need synchronization, risking deadlock. A single gen_statem with both orchestration and agent capabilities is simpler and correct.
- **Research on Sonnet, not Haiku.** Research quality determines plan quality, which determines everything. The marginal cost of Sonnet for 3-5 research Runners is negligible compared to the cost of a bad plan.

### Open questions (resolve before Ready)

- **Merge conflict resolution quality.** Can an LLM reliably resolve git merge conflicts? Need to test with realistic conflicts. Fallback: flag conflicts for the user instead of auto-resolving.
- **Lead-to-Lead communication.** Currently Leads only communicate through the Site Log. Is there a need for direct steering between Leads, or is the Foreman always the right intermediary?
- **Compile-check language generality.** The spec mentions `mix compile` but Deft should work for any language. Need a language-detection mechanism and per-language compile/lint commands.
- **Job completion notification.** If the user walks away, how are they notified? Desktop notification? Email? Just persist results and show on next `deft resume`?

## References

- [harness.md](harness.md) — Deft foundation spec
- [observational-memory.md](observational-memory.md) — per-agent context management
- [specd_decisions.jsonl](../specd_decisions.jsonl) — inspiration for the Site Log format
