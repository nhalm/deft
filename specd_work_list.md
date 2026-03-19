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

## orchestration v0.3

- Fix `determine_completed_deliverables` key parsing (foreman.ex:2474-2509): `generate_site_log_key(:complete, metadata)` produces `"complete-<session_id>-<deliverable_name>-<timestamp>"` but `String.split(key, "-", parts: 3)` splits at the first two hyphens, giving wrong lead_id when session_id contains hyphens (UUIDs); use a delimiter that doesn't appear in UUIDs or store lead_id as a separate field
- Enforce `job.max_leads` config (default 5) in `get_ready_deliverables` or `start_ready_leads`: currently all ready deliverables are started simultaneously with no cap (foreman.ex:1992-2003)
- Spawn merge-resolution Runner on merge conflict instead of discarding work: `handle_merge_conflict` (foreman.ex:1288-1303) sends a `:critical_finding` and deletes the Lead's worktree, permanently losing the Lead's work; spec section 3.4 requires spawning a merge-resolution Runner to resolve conflicts

## git-strategy v0.1

- Delete Lead branch after successful merge and test: add `git branch -d deft/lead-<id>` call after `cleanup_worktree` in `handle_test_success` (foreman.ex:1245-1261); currently only the worktree is removed, leaving orphaned branches that accumulate and require manual `deft startup` cleanup
- Wire `GitJob.create_job_branch/1` into Foreman startup: function exists (job.ex:49) but is never called from foreman.ex or anywhere else; `create_lead_worktree` references `deft/job-<job_id>` branch that was never created, causing worktree creation to fail with "not a valid object name"
- Handle post-merge test failure by removing Lead from tracking and spawning fix-up Runner or flagging user: `handle_test_failure` (foreman.ex:1264-1273) sends a `:critical_finding` but leaves the Lead in `data.leads`, so `all_leads_complete?` never returns true and the job hangs in `:executing` permanently; spec section 3 step 4 requires fix-up Runner or user intervention

## filesystem v0.3

- Fix `generate_site_log_key` to produce stable keys for overwritable entries: currently appends millisecond timestamp to every key (foreman.ex:1349-1354), making all keys unique; spec section 5.4 requires "same key replaces the previous entry" — semantic entries like contracts and decisions should use stable keys (e.g. `"contract-<deliverable_name>"`) so updates overwrite previous values
- Use `File.realpath/1` (or `:file.read_link_all/1`) instead of `Path.expand/1` in `resolve_real_path` (project.ex:126-128): `Path.expand/1` normalizes `~` and relative paths but does not resolve symlinks; two symlinked paths to the same repo produce different encoded project directories, siloing sessions and cache

