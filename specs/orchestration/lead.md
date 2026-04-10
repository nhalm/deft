# Lead

| | |
|--------|----------------------------------------------|
| Version | 0.17 |
| Status | Ready |
| Last Updated | 2026-04-10 |

## Changelog

### v0.17 (2026-04-10)
- Extracted from orchestration.md with new naming (LeadAgent → Lead, Lead gen_statem → Lead.Coordinator)

## Overview

A Lead manages one deliverable end-to-end. It is a `Deft.Agent` instance that decomposes work, steers Runners, evaluates output, and publishes interface contracts. The **Lead.Coordinator** is its paired gen_statem that handles Runner lifecycle, contract publishing, and reporting to the Foreman.Coordinator.

**Scope:**
- Lead agent behavior (planning, execution, verification)
- Lead.Coordinator state machine
- Lead↔Lead.Coordinator interface
- Runner management
- Contract publishing
- Reporting to Foreman

**Dependencies:**
- [coordinator.md](coordinator.md) — Foreman.Coordinator that manages Lead lifecycle
- [runners.md](runners.md) — Runner types and tool sets
- [../harness.md](../harness.md) — `Deft.Agent` behavior

## Specification

### 1. Lead↔Lead.Coordinator Interface

Same pattern as Foreman↔Coordinator. The Lead.Coordinator sends prompts to the Lead. The Lead has tools that send messages to the Lead.Coordinator:

| Tool | Message to Lead.Coordinator | Purpose |
|------|---------------------------|---------|
| `spawn_runner` | `{:agent_action, :spawn_runner, type, instructions}` | Start a Runner task |
| `publish_contract` | `{:agent_action, :publish_contract, content}` | Satisfy an interface contract |
| `report_status` | `{:agent_action, :report, type, content}` | Send progress to Foreman |
| `request_help` | `{:agent_action, :blocker, description}` | Escalate to Foreman |

### 2. Lead.Coordinator States

```
:planning --> :executing --> :verifying --> :complete
```

| Phase | Lead.Coordinator does | Lead does |
|-------|---------------------|----------|
| `:planning` | Sends deliverable assignment + context to Lead | Reads assignment, research findings, contracts from site log. Decomposes into task list. |
| `:executing` | Spawns Runners on request, collects results, sends to Lead | Evaluates Runner output, decides next tasks, calls `spawn_runner` / `publish_contract` / `report_status` |
| `:verifying` | Spawns testing Runner. Queues any incoming steering messages. | (idle — waiting for verification) |
| `:complete` | Checks queued steering first — if steering triggers re-execution, re-enters `:executing` without notifying Foreman. Only sends `:complete` when no queued steering triggers re-execution. | Generates deliverable summary |

### 3. Active Steering

The Lead is a **pair-programming manager**: plans tasks with rich context, requests Runners with detailed instructions (via `spawn_runner` tool), evaluates Runner output, requests corrective Runners if needed, updates its task list, requests testing Runners to verify compile checks and tests after each implementation Runner, and reports progress to the Foreman (via `report_status` tool).

The Lead's own tool set is read-only (read, grep, find, ls) plus the Lead-specific tools above.

The Lead.Coordinator handles `{:coordinator_steering, content}` messages from the Foreman.Coordinator and injects them into the Lead as prompts. Exception: in `:verifying` state, steering is queued and applied after verification completes.

### 4. Contract Publishing

When the Lead completes work that satisfies a dependency, it calls the `publish_contract` tool. The Lead.Coordinator sends `{:lead_message, :contract, content, metadata}` to the Foreman.Coordinator.

### 5. Worktree

Each Lead operates in its own git worktree. The Foreman.Coordinator creates it when the Lead starts, and handles merge and cleanup when the Lead completes. See [../git-strategy.md](../git-strategy.md).

### 6. Reporting

The Lead.Coordinator sends messages to the Foreman.Coordinator via `send(coordinator_pid, {:lead_message, type, content, metadata})`:
- `:status` — progress updates
- `:decision` — implementation choices with rationale
- `:artifact` — files created or modified
- `:contract` / `:contract_revision` — interface definitions
- `:plan_amendment` — "my deliverable also needs X"
- `:complete` — deliverable finished, ready for merge
- `:blocker` — stuck, needs Foreman help
- `:error` — something went wrong
- `:critical_finding` — auto-promoted to site log
- `:finding` — forwarded Runner findings (Lead may tag as `shared`)

### 7. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.lead_model` | `"claude-sonnet-4"` | Model for Leads |
| `job.max_runners_per_lead` | `3` | Maximum concurrent Runners per Lead |
| `job.runner_timeout` | `300_000` | Timeout for implementation Runners (ms) |

## References

- [coordinator.md](coordinator.md) — Foreman.Coordinator
- [runners.md](runners.md) — Runner types
- [protocol.md](protocol.md) — message types
- [../harness.md](../harness.md) — Deft.Agent
- [../git-strategy.md](../git-strategy.md) — worktree management
