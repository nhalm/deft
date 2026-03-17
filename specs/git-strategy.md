# Git Strategy

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Ready |
| Last Updated | 2026-03-17 |

## Changelog

### v0.1 (2026-03-17)
- Extracted from orchestration.md v0.2 — git worktree strategy, merge, cleanup, orphan recovery

## Overview

Deft uses git worktrees to give each Lead an isolated copy of the codebase for parallel execution. A job branch (`deft/job-<job_id>`) serves as the integration point. Each Lead gets its own worktree branched from the job branch, commits work as it progresses, and the Foreman merges completed Lead branches back in dependency order. On job completion, all work is squash-merged into the original branch.

**Scope:**
- Job branch creation and lifecycle
- Per-Lead worktree creation, branching, and cleanup
- Merge strategy (dependency order, conflict resolution)
- Job completion (squash-merge, branch cleanup)
- Job failure/abort (worktree cleanup, branch deletion)
- Startup orphan cleanup

**Out of scope:**
- Orchestration logic (see [orchestration.md](orchestration.md))
- User's broader git workflow (rebasing, remote push, CI)

**Dependencies:**
- [orchestration.md](orchestration.md) — Foreman/Lead lifecycle, process architecture

**Design principles:**
- **True isolation.** Each Lead has its own working tree. No file locking, no coordination on disk.
- **Merge at the right time.** Conflicts are resolved at merge time, which is the correct place to handle them — not via file ownership restrictions.
- **Clean failure.** Aborted or failed jobs leave the original branch untouched. No partial work leaks.
- **No orphans.** Startup cleanup detects and removes artifacts from prior crashed jobs.

## Specification

### 1. Job Branch Creation

On job start:
1. Verify the working tree is clean. If there are uncommitted changes, warn the user and ask to stash.
2. Create a job branch from current HEAD: `deft/job-<job_id>`

The job branch is the integration target — all Lead branches merge into it. The original branch is not modified until final squash-merge on job completion.

### 2. Per-Lead Worktrees

When the Foreman starts a Lead:
1. Create a worktree: `git worktree add <path> -b deft/lead-<lead_id>`
2. The worktree branches from `deft/job-<job_id>` plus any already-merged Lead work (so later Leads see earlier Leads' completed work)
3. Worktree path: a temporary directory managed by Deft (e.g., `<repo>/.deft-worktrees/lead-<lead_id>`)
4. Runners operate in the Lead's worktree directory
5. Leads commit their work within the worktree as they progress (per-task or per-milestone commits)

### 3. Merge Strategy

When a Lead sends `{:lead_message, :complete, ...}` to the Foreman:

1. The Foreman merges the Lead's branch into `deft/job-<job_id>`
2. If merge conflicts occur, the Foreman spawns a **merge-resolution Runner** that reads both versions and produces the merged result
3. **Post-merge testing:** Foreman runs the test suite (`mix test` or equivalent) on the merged job branch to catch semantic conflicts early — not just at final verification
4. If merge or tests fail, Foreman spawns a fix-up Runner or flags for user intervention
5. On success, Foreman cleans up the worktree (`git worktree remove <path>`)
6. Lead process terminates

**Merge order:** Follows the dependency DAG. Independent Leads that ran in parallel are merged in completion order.

**Dependent Leads:** Any Lead that starts after a merge gets the merged base, so it sees all previously completed work.

### 4. Job Completion

After verification passes:
1. Squash-merge `deft/job-<job_id>` into the original branch
2. The user sees a single commit (or can choose to keep individual commits via config)
3. Delete the job branch: `git branch -d deft/job-<job_id>`
4. Verify no worktrees remain: `git worktree list` should show only the main working tree

### 5. Job Failure / Abort

If the job is aborted or fails:
1. All Lead worktrees are cleaned up (`git worktree remove` for each)
2. The job branch is deleted (configurable: `job.keep_failed_branches`)
3. The original branch is untouched — no partial work leaks

### 6. Startup Orphan Cleanup

On Deft launch, scan for orphaned artifacts from prior crashed jobs:
- `deft/job-*` branches that have no running Deft job
- `deft/lead-*` worktrees that have no running Deft job

**Interactive mode:** Offer to clean them up (user confirmation).
**Non-interactive mode** (with `--auto-approve-all`): Clean automatically.

Cleanup steps:
1. `git worktree remove <path>` for each orphaned worktree
2. `git branch -D <branch>` for each orphaned branch
3. `git worktree prune` to clean up stale worktree metadata

### 7. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.test_command` | `"mix test"` | Command to run after merging a Lead's work (language-specific) |
| `job.keep_failed_branches` | `false` | Keep job branches on failure/abort (for debugging) |
| `job.squash_on_complete` | `true` | Squash-merge into original branch (false = merge with history) |

## Notes

### Design decisions

- **Git worktrees over file ownership.** File ownership prevents Leads from doing their job when work naturally crosses file boundaries. Worktrees provide true isolation — each Lead has its own copy of the codebase.
- **Job branch as integration target.** Merging into a job branch (not directly into main/original) means we can test the integrated result before touching the user's branch. The squash-merge at the end is a clean, reversible operation.
- **Foreman owns merge, not Lead.** The Lead should not merge its own work — it avoids a race between the merge-complete message and Lead process death. The Foreman handles merge after receiving `:complete`.
- **Post-merge testing.** Running tests after each merge (not just at final verification) catches semantic conflicts early when there are fewer changes to debug.

## References

- [orchestration.md](orchestration.md) — job lifecycle, Foreman/Lead/Runner hierarchy
