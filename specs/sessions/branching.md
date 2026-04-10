# Session Branching

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Draft |
| Last Updated | 2026-04-10 |

## Changelog

### v0.1 (2026-04-10)
- Initial spec — user-initiated session branching from checkpoints, git state restore

## Overview

Session branching lets users fork a session from an earlier point and try a different approach. A branch creates a new session that copies the full history up to the branch point — conversation, OM state, and git state are all restored. The original session is untouched.

This gives users the ability to recover from wrong turns. Instead of undoing work manually or starting over, they rewind to before the mistake and explore a different path. The Foreman/Lead hierarchy steers decisions forward; branching lets the user steer backward when the forward path was wrong.

**Scope:**
- Checkpoints — named snapshots within a session (explicit and automatic)
- Branching — creating a new session from a checkpoint
- Git state restore on branch
- User commands (`/checkpoint`, `/branch`)
- Session lineage (parent/child relationships)

**Out of scope:**
- Orchestrated job branching — branching within a multi-Lead job involves worktree state, Lead progress, site log, and DAG position. Deferred to a future version.
- Agent-initiated branching — the Foreman deciding to backtrack autonomously. User-initiated only for now.
- Branch comparison or diffing between sibling sessions.

**Dependencies:**
- [persistence.md](persistence.md) — JSONL format, `checkpoint` entry type
- [context.md](context.md) — context reconstruction from message history
- [../git-strategy.md](../git-strategy.md) — git operations

## Specification

### 1. Checkpoints

A checkpoint is a named snapshot of session state at a specific point in the conversation. Checkpoints are recorded as `checkpoint` entries in the session JSONL.

#### 1.1 Checkpoint Entry

```json
{
  "type": "checkpoint",
  "label": "before-auth-refactor",
  "entry_index": 47,
  "git_ref": "a1b2c3d4",
  "timestamp": "2026-04-10T14:30:00Z"
}
```

| Field | Description |
|-------|-------------|
| `label` | Human-readable name. Must be unique within the session. |
| `entry_index` | The JSONL line number of the entry immediately before this checkpoint. This is the "branch point" — branching from this checkpoint restores session state up to this point. |
| `git_ref` | The HEAD commit SHA of the working directory at checkpoint time. |
| `timestamp` | When the checkpoint was created. |

#### 1.2 Explicit Checkpoints

Users create checkpoints with the `/checkpoint` command:

```
/checkpoint before-auth-refactor
```

If no label is provided, one is auto-generated from the timestamp: `cp-20260410-143000`.

#### 1.3 Automatic Checkpoints

Deft creates checkpoints automatically at these moments:
- **Session start** — a checkpoint named `session-start` is always the first entry after `session_start`
- **Before compaction** — a checkpoint is created before context is compacted, since compaction destroys history that branching would need. Label: `pre-compaction-<N>` where N is the compaction count.

Automatic checkpoints use the same entry format. They are visible in `/checkpoint list` but marked as `auto: true` in the entry.

### 2. Branching

Branching creates a new session from a checkpoint in the current session.

#### 2.1 Branch Command

```
/branch <checkpoint-label>
```

Lists available checkpoints if no label is given. The user selects one.

#### 2.2 Branch Process

When the user branches from checkpoint C in session S:

1. **Create new session ID.** Generate a new session ID for the branch.
2. **Copy session state.** Restore conversation history and OM state up to C's `entry_index`. The new session's `session_start` entry is rewritten with the new session ID and branch metadata.
3. **Record branch metadata.** The new session's `session_start` entry includes:
   - `parent_session_id` — the original session S
   - `branch_checkpoint` — the label of checkpoint C
   - `branch_entry_index` — C's entry_index
4. **Restore git state.** Create a new branch from C's `git_ref`:
   - Branch name: `deft/branch-<new_session_id_short>`
   - `git checkout -b <branch_name> <git_ref>`
   - This preserves the original branch untouched.
5. **Switch to new session.** The web UI navigates to the new session. The user sees the conversation history up to the checkpoint and can continue from there.

#### 2.3 What Gets Copied

| State | Restored? | How |
|-------|-----------|-----|
| Conversation history | Yes | Session entries copied up to branch point |
| OM observations | Yes | OM state at or before the branch point is restored |
| Git working tree | Yes | New branch from checkpoint's commit SHA |
| Uncommitted changes | No | Only committed state is captured. The checkpoint's `git_ref` is a commit SHA. |
| Configuration | Yes | From the original `session_start` entry's config snapshot |

#### 2.4 What Does NOT Get Copied

- **Entries after the checkpoint** — the whole point is to diverge from that point
- **Uncommitted file changes** — checkpoints capture committed git state only. If the user wants to preserve uncommitted work, they should commit first (or Deft should warn if there are uncommitted changes when creating a checkpoint).
- **External state** — database changes, API calls, file changes outside the repo are not tracked or restored

### 3. Session Lineage

Sessions form a tree via `parent_session_id` references.

#### 3.1 Lineage Display

The session picker shows branched sessions with their parent relationship:
- Parent sessions show a branch indicator if children exist
- Child sessions show which parent and checkpoint they branched from
- Lineage is informational only — there are no operations that act on the tree as a whole

#### 3.2 Session Listing

Branched sessions appear in the normal session list. They are sorted by last activity like any other session. The `parent_session_id` and `branch_checkpoint` fields in `session_start` are the only structural difference.

### 4. User Commands

| Command | Action |
|---------|--------|
| `/checkpoint <label>` | Create a named checkpoint at the current point |
| `/checkpoint list` | List all checkpoints in the current session |
| `/branch <label>` | Create a new session from the named checkpoint |
| `/branch` (no args) | List checkpoints and prompt user to select one |

### 5. Constraints

- **User sessions only.** Branching is not supported for agent sessions (Foreman, Lead). Those sessions are internal and not user-facing.
- **Committed state only.** Checkpoints capture the HEAD commit SHA, not uncommitted changes. `/checkpoint` warns if there are uncommitted changes in the working directory.
- **No concurrent branches.** Branching switches the user to the new session. The original session remains available for resume but is not active.
- **Checkpoint labels are unique per session.** Attempting to create a checkpoint with a duplicate label returns an error.

## Notes

### Design decisions

- **New session over in-place rewind.** Branching creates a new session rather than modifying the current one. This preserves the original session as a record of what happened — useful for understanding what went wrong. It also avoids the complexity of "undoing" JSONL entries in an append-only log.
- **Git branch over checkout.** Creating a new git branch from the checkpoint's SHA (rather than `git checkout` to detach HEAD or rewind the current branch) keeps the original branch intact. The user can always return to where they were.
- **Committed state only over full working tree snapshots.** Capturing uncommitted changes would require `git stash` or a temporary commit, adding complexity and edge cases (untracked files, ignored files, binary files). Limiting to committed state keeps the model clean. The tradeoff is that users must commit before checkpointing if they want to preserve in-progress work.
- **Pre-compaction automatic checkpoints.** Compaction destroys the conversation history that branching needs. Auto-checkpointing before compaction ensures there's always a recovery point, even if the user didn't think to checkpoint manually.
- **User-initiated only for now.** Agent-initiated branching (the Foreman deciding "this approach failed, let me try from an earlier state") is a natural extension but adds significant complexity — the agent needs to evaluate its own decision quality, choose a branch point, and manage the branch lifecycle. Better to validate the mechanism with user-initiated branching first.

### Future considerations

- **Orchestrated job branching.** Would need to snapshot: site log state, Lead progress, worktree contents, DAG position, contract state. Much harder than user session branching.
- **Agent-initiated branching.** The Foreman or Lead could recognize a dead end and propose branching to the user, or autonomously branch in `--auto-approve-all` mode.
- **Branch comparison.** Diffing two sibling sessions to understand what different decisions led to different outcomes.

## References

- [persistence.md](persistence.md) — JSONL format, checkpoint entry type
- [context.md](context.md) — context reconstruction
- [../git-strategy.md](../git-strategy.md) — git branch and worktree management
- [../orchestration/README.md](../orchestration/README.md) — Foreman/Lead hierarchy (future: job branching)
