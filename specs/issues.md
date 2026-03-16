# Issues

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Draft |
| Last Updated | 2026-03-16 |

## Changelog

### v0.1 (2026-03-16)
- Initial spec — persistent issue tracker with interactive creation session, structured JSON storage, dependency DAG, `deft work` loop with single-approval, 90-day closed issue compaction. Inspired by Seeds/Beads concepts on JSONL+git storage.

## Overview

Issues are Deft's persistent work queue. They let users (and Deft itself) track bugs, tasks, and features across sessions. The issue tracker is deliberately minimal — JSONL storage, git-native merging, dependency tracking, and a `ready` queue that feeds into the orchestration layer.

The core loop: user creates issues → `deft work` picks the highest-priority unblocked issue → Foreman runs a job → issue is closed → repeat.

**Scope:**
- Issue CRUD (create, update, close, list, show)
- Dependency tracking (blocked-by)
- Priority levels
- `ready` queue (unblocked, open issues)
- Storage as JSONL with git merge support
- CLI commands (`deft issue ...`, `deft work`)
- Integration with orchestration (Foreman picks from queue, closes on completion)
- Agent-created issues (Deft logs issues during sessions for out-of-scope work)

**Out of scope:**
- Templates / molecules / workflow patterns (future — add if we find ourselves repeating issue structures)
- Labels / tagging (future — add when filtering becomes painful without them)
- Messaging / threading between agents (Site Log handles intra-job communication)
- Remote sync / federation (git push handles that)
- MCP server for external agent access (future)
- Interactive issue editing session (`deft issue update <id> --edit`)

**Dependencies:**
- [sessions.md](sessions.md) — CLI interface, config
- [orchestration.md](orchestration.md) — Foreman integration for `deft work`

**Design principles:**
- **The JSONL file is the database.** No binary storage, no daemon. One JSON object per line, fully diffable, git-mergeable.
- **Git is the audit trail.** No built-in history tracking — `git log .deft/issues.jsonl` shows who changed what and when.
- **Minimal viable tracker.** Issues, dependencies, priorities. No labels, no milestones, no assignees until we need them.
- **Issues feed jobs.** The issue tracker exists to give the Foreman a queue to pull from. It's not a standalone product.

## Specification

### 1. Storage

#### 1.1 File Layout

```
.deft/
  issues.jsonl       # All issues, one JSON object per line
```

The file lives in the project directory, not in `~/.deft/`. It's meant to be committed to git.

#### 1.2 Git Merge Strategy

Add to `.gitattributes`:
```
.deft/issues.jsonl merge=union
```

`merge=union` takes lines from both sides on branch merge. Since each issue is one line with a unique ID, parallel work on different branches merges cleanly. On read, if duplicate IDs exist (same issue modified on both branches), last occurrence wins (dedup-on-read).

#### 1.3 Concurrency

Within a single Deft process, the `Deft.Issues` GenServer serializes all writes. Concurrent writes from multiple Deft processes (rare — typically one user, one machine) use advisory file locking:

- Lock file: `.deft/issues.jsonl.lock`
- Atomic creation via `File.open!(path, [:write, :exclusive])`
- Stale threshold: 30 seconds (delete and retry if lock file is older)
- Retry: 100ms with jitter, 10 second timeout
- Writes go to a temp file (`.deft/issues.jsonl.tmp.<random>`) then `File.rename/2` (POSIX-atomic)

#### 1.4 Worktree Awareness

When running from a git worktree (as Leads do), resolve to the main repo's `.deft/issues.jsonl`. Detect via `git rev-parse --git-common-dir`. Issue writes from worktrees should be rare — typically only the Foreman (in the main worktree) modifies issues.

### 2. Issue Schema

```
id                  :: String.t()           # Hash-based short ID, e.g. "deft-a1b2"
title               :: String.t()           # One-line summary
context             :: String.t()           # What and why — background, motivation, relevant details
acceptance_criteria :: [String.t()]         # List of concrete conditions that define "done"
constraints         :: [String.t()]         # Implementation constraints ("use argon2", "don't change public API")
status              :: :open | :in_progress | :closed
priority            :: 0..4                 # 0=critical, 1=high, 2=medium (default), 3=low, 4=backlog
dependencies        :: [String.t()]         # List of issue IDs this is blocked by
created_at          :: String.t()           # ISO 8601 UTC
updated_at          :: String.t()           # ISO 8601 UTC
closed_at           :: String.t() | nil     # ISO 8601 UTC, set when status → :closed
source              :: :user | :agent       # Who created it
job_id              :: String.t() | nil     # Job ID if closed by a job
```

The structured fields (`context`, `acceptance_criteria`, `constraints`) are populated by the interactive creation session. They give the Foreman clean, parseable input — no markdown conventions or heuristic parsing needed.

#### 2.1 ID Generation

IDs use the format `deft-<hex>` where `<hex>` is 4 hex characters derived from a random UUID. This gives 65,536 possible IDs — sufficient for a single-project issue tracker. On collision (same 4-char prefix already exists), extend to 5 characters, then 6, etc.

#### 2.2 JSONL Format

Each issue is serialized as a single JSON line:

```json
{"id":"deft-a1b2","title":"Add JWT auth","context":"The API has no authentication. Need JWT-based auth for frontend requests.","acceptance_criteria":["POST /auth/register returns 201 with JWT","POST /auth/login returns 200 with JWT","Invalid tokens return 401"],"constraints":["Use argon2","Don't modify User schema"],"status":"open","priority":1,"dependencies":[],"created_at":"2026-03-16T22:00:00Z","updated_at":"2026-03-16T22:00:00Z","closed_at":null,"source":"user","job_id":null}
```

Mutations rewrite the file atomically (read all → modify → write temp → rename). Creates can append under lock for performance, but the file is small enough that full rewrite is fine.

### 3. Dependency Tracking

Dependencies are directional: issue A lists issue B in its `dependencies` field, meaning "A is blocked by B."

An issue is **ready** when:
- Status is `:open`
- All issues in its `dependencies` list have status `:closed`

An issue is **blocked** when:
- Status is `:open`
- At least one issue in its `dependencies` list has status `:open` or `:in_progress`

Circular dependency detection: on create or update, walk the dependency graph. If adding a dependency would create a cycle, reject with an error.

### 4. Process Architecture

```
Deft.Issues (GenServer — owns .deft/issues.jsonl)
```

- Started by `Deft.Application` if `.deft/issues.jsonl` exists or on first `deft issue create`
- Holds all issues in memory (list of structs)
- Writes serialize through the GenServer (atomic file rewrite)
- Reads are direct from GenServer state (no ETS needed — issue count is small)

### 5. CLI Commands

#### 5.1 Issue Creation (Interactive Session)

```
deft issue create <title> [--priority <0-4>] [--blocked-by <id>,...]
```

`deft issue create` starts a short interactive AI session to help the user write the issue. The flow:

1. User provides the title (required) and optional flags
2. Deft starts a lightweight session (same Agent loop, no OM) with a system prompt focused on issue elicitation
3. Deft asks clarifying questions — one or two rounds:
   - What's the context? Why does this need to happen?
   - What does "done" look like? (acceptance criteria)
   - Any constraints on how it should be done?
   - Does this depend on other issues? (shows open issues if relevant)
4. User answers conversationally — Deft extracts structure from the conversation
5. Deft presents the structured issue for confirmation:
   ```
   Issue: Add JWT auth to the API
   Priority: high

   Context:
   The API currently has no authentication. We need JWT-based auth
   so the frontend can make authenticated requests.

   Acceptance Criteria:
   - POST /auth/register accepts email+password, returns 201 with JWT
   - POST /auth/login verifies credentials, returns 200 with JWT
   - Invalid/expired tokens return 401
   - Tokens expire after 24 hours

   Constraints:
   - Use argon2 for password hashing
   - Don't modify the existing User schema — add a separate Credential model

   [Save / Edit / Cancel]
   ```
6. User confirms → issue is saved to `.deft/issues.jsonl`

**Quick mode:** `deft issue create "fix the typo in README" --quick` skips the interactive session and creates the issue with just a title (empty context, criteria, constraints). For trivial issues where a conversation would be overkill.

#### 5.2 Other Issue Commands

```
deft issue show <id>
deft issue list [--status open|in_progress|closed] [--priority <0-4>]
deft issue ready                    # Open issues with no unresolved blockers, sorted by priority
deft issue update <id> [--title <t>] [--priority <p>] [--status <s>] [--blocked-by <ids>]
deft issue close <id>
deft issue dep add <id> --blocked-by <blocker_id>
deft issue dep remove <id> --blocked-by <blocker_id>
```

Default `list` shows open and in_progress issues. `--status closed` to see closed issues.

`ready` output is sorted by priority (0 first), then by created_at (oldest first).

`update` can also start an interactive session to refine the issue: `deft issue update <id> --edit` reopens the conversational flow with existing fields pre-populated.

#### 5.3 Work Mode

```
deft work                           # Pick highest-priority ready issue, run as job
deft work <id>                      # Run a specific issue as a job
deft work --loop                    # Keep picking and running until queue empty or cost ceiling
```

`deft work` without arguments:
1. Call `ready` to get unblocked issues sorted by priority
2. Pick the first one
3. Set status to `:in_progress`
4. Start a Foreman job with the issue's structured fields as the prompt
5. On job completion: set status to `:closed`, record `job_id`
6. On job failure/abort: set status back to `:open`

`deft work --loop`:
1. Same as above, but after closing an issue, check for more ready issues
2. **Single approval:** The user approves the Foreman's plan for the first issue. All subsequent issues in the loop auto-approve. This gives the user a chance to verify Deft's approach without requiring babysitting.
3. Stop when: no ready issues remain, cumulative cost exceeds `work.cost_ceiling` (separate from per-job ceiling), or user aborts (Ctrl+C)
4. Between jobs: unblock any issues whose dependencies were just closed

### 6. Foreman Integration

#### 6.1 Job Start from Issue

When a job starts from `deft work`, the Foreman receives the issue as structured JSON:

```json
{
  "id": "deft-a1b2",
  "title": "Add JWT auth to the API",
  "priority": 1,
  "context": "The API currently has no authentication. We need JWT-based auth so the frontend can make authenticated requests.",
  "acceptance_criteria": [
    "POST /auth/register accepts email+password, returns 201 with JWT",
    "POST /auth/login verifies credentials, returns 200 with JWT",
    "Invalid/expired tokens return 401",
    "Tokens expire after 24 hours"
  ],
  "constraints": [
    "Use argon2 for password hashing",
    "Don't modify the existing User schema — add a separate Credential model"
  ]
}
```

The Foreman uses the structured fields directly:
- `context` informs the research and planning phases
- `acceptance_criteria` become verification targets in the `:verifying` phase
- `constraints` are injected as steering instructions for Leads

#### 6.2 Agent-Created Issues

During any session (interactive or job), the agent can create issues for work it identifies but considers out of scope:

- The agent has access to an `issue_create` tool (or calls `Deft.Issues.create/1` internally)
- Agent-created issues have `source: :agent` and default priority 3 (low)
- The agent should create issues for: discovered bugs, needed refactors, TODO items found in code, follow-up work from the current task
- The agent should NOT create issues for: the current task itself, trivial observations

#### 6.3 Issue Closure from Job

When a Foreman job completes successfully:
1. If the job was started from an issue (`deft work`), close the issue automatically
2. Record the `job_id` on the issue for traceability
3. Check if closing this issue unblocks other issues — log this to the user

### 7. Closed Issue Compaction

Closed issues older than 90 days are compacted out of `.deft/issues.jsonl`.

Compaction runs automatically on `deft` startup (same as orphan worktree cleanup). The process:
1. Read all issues
2. Filter out issues where `status == :closed` and `closed_at` is more than 90 days ago
3. Rewrite the JSONL file without the compacted issues
4. Log to the user: "Compacted N closed issues older than 90 days"

Compacted issues are not archived — `git log .deft/issues.jsonl` preserves the full history. The JSONL file only needs to hold active and recently-closed issues.

### 8. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `work.cost_ceiling` | `50.00` | Maximum cumulative spend for `deft work --loop` ($) |
| `issues.compaction_days` | `90` | Days after close before compacting an issue |

Work mode inherits all `job.*` configuration from the orchestration spec. `deft work --loop` uses single-approval: user approves the first job's plan, subsequent jobs auto-approve.

## Notes

### Design decisions

- **JSONL over SQLite.** Consistent with Site Log and session storage. The issue list is small (tens to hundreds of issues, not thousands). Full file rewrite on mutation is acceptable at this scale and keeps the implementation trivial.
- **Interactive creation session, structured JSON output.** Humans are bad at writing structured data. AIs are bad at parsing unstructured data. The creation session lets the human speak naturally while the AI extracts structure. The Foreman reads clean JSON — no markdown conventions or heuristic parsing. The `--quick` flag provides an escape hatch for trivial issues.
- **Structured fields over freeform description.** `context`, `acceptance_criteria`, and `constraints` give the Foreman specific, actionable input. Acceptance criteria become verification targets. Constraints become Lead steering instructions. This is better than a freeform description the Foreman has to interpret.
- **Single approval for loop mode.** First job gets user approval — validates that Deft's approach makes sense. Subsequent jobs auto-approve. This balances oversight with autonomy. The user can always Ctrl+C if something goes wrong.
- **90-day compaction.** Closed issues are removed from the JSONL after 90 days. Git history preserves the full record. This keeps the file small and focused on active work. Configurable via `issues.compaction_days`.
- **No labels/tags in v0.1.** Priority + dependencies cover the core need (what to work on next). Labels add filtering complexity that isn't justified until the issue count grows. Easy to add later without schema migration (just add a `labels` field).
- **No assignees.** Deft is single-user. If we add multi-agent assignment later, it maps cleanly to `assignee` on the schema.
- **`merge=union` over custom merge driver.** Git's built-in line-union strategy handles the common case (different issues modified on different branches). Dedup-on-read handles the rare case (same issue modified on both branches — last line wins). No custom tooling needed.
- **Inspired by Seeds, not a port.** Seeds validates the JSONL+git approach. We take the concepts (ready queue, hash IDs, merge=union, atomic writes) but implement natively in Elixir/OTP with GenServer instead of file locks for the common case.
- **Agent-created issues are low priority by default.** The agent shouldn't flood the queue with work the user didn't ask for. Low priority means they're visible but won't be auto-picked by `deft work` before user-created issues.

## References

- [orchestration.md](orchestration.md) — Foreman, job lifecycle
- [sessions.md](sessions.md) — CLI interface
- [Seeds](https://github.com/jayminwest/seeds) — JSONL+git issue tracker for AI agents (architectural inspiration)
- [Beads](https://github.com/steveyegge/beads) — distributed graph issue tracker (concept inspiration)
