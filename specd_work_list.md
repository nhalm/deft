# Work List

<!--
Single execution queue for all work — spec implementations, audit findings, and promoted review items.

HOW IT WORKS:

1. Pick an unblocked item (no `(blocked: ...)` annotation)
2. Implement it
3. Validate cross-file dependencies
4. Move the completed item from this file to specd_history.md
5. Check this file for items whose `(blocked: ...)` annotation references the
   work you just completed — remove the annotation to unblock them
6. Delete the spec header in this file if no more items are under it
7. LOOP_COMPLETE when this file has no unblocked items remaining

POPULATED BY: /specd:plan command (during spec phase), /specd:audit command, /specd:review-intake command, and humans.
-->

## sessions/branching v0.1

- Add `/checkpoint <label>` command handler — validate label uniqueness within session, check for uncommitted changes (warn but don't block), write checkpoint entry to session
- Add `/checkpoint list` command handler — read session JSONL, filter for `type: "checkpoint"` entries, display label, timestamp, and auto/manual indicator
- Auto-generate checkpoint label from timestamp (`cp-YYYYMMDD-HHMMSS`) when `/checkpoint` is called with no label argument
- Add automatic `session-start` checkpoint — after writing the `session_start` entry, immediately write a checkpoint with label `session-start` and `auto: true`
- Add automatic pre-compaction checkpoint — before compaction summarizes and removes messages, write a checkpoint with label `pre-compaction-<N>` and `auto: true`
- Add `Deft.Session.Branch` module — given a source session, checkpoint label, and new session ID: restore conversation history and OM state up to the checkpoint's `entry_index` into a new session, rewriting `session_start` with new ID and `parent_session_id`/`branch_checkpoint`/`branch_entry_index`
- Add git branch creation on session branch — after restoring session state, create and switch to `deft/branch-<session_id_short>` from the checkpoint's `git_ref` (blocked: Add `Deft.Session.Branch` module)
- Add `/branch <label>` command handler — validate checkpoint exists, call `Deft.Session.Branch`, then navigate web UI to the new session. When called with no args, list checkpoints and prompt for selection (blocked: Add `Deft.Session.Branch` module)
- Add parent/child indicators to session picker in web UI — read `parent_session_id` from `session_start` entries, show branch icon on parents with children, show "branched from <parent> at <checkpoint>" on child sessions (blocked: Add `/branch <label>` command handler)

