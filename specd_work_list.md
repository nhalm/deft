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

- Derive `publishing_deliverable` from Foreman's Lead tracking map instead of metadata in `process_lead_message(:contract, ...)` (foreman.ex:1343-1344): code reads `Map.get(metadata, :deliverable_name)` but Lead's `send_lead_message/4` never populates this key; `contract_matches?` always returns `false` (line 2514 guards `publishing_deliverable != nil`); contract-based dependency unblocking never fires

## git-strategy v0.1

- Guard `{:executing, :idle}` enter handler against resume: `create_job_branch` is called unconditionally on entering `{:executing, :idle}` (foreman.ex:355-373); resume enters this state (foreman.ex:270) but the branch already exists; `create_branch` fails and the enter handler transitions to `{:complete, :idle}`, immediately aborting the resumed job
- Commit resolved files in merge-resolution Runner before retrying merge (foreman.ex:825,831,1651-1661): Runner instructions say "stage the resolved files using git add" but never commit; `cleanup_worktree` at line 825 removes the worktree (and staged files) before `handle_lead_merge` retry at line 831 creates a new merge worktree with the same unresolved conflicts
- Change `delete_lead_branch` to use `git branch -D` (force delete) instead of `-d` (foreman.ex:1850): merge happens in a temporary worktree, not the main HEAD; from the main repo's perspective the lead branch is never merged; `-d` always fails with "not fully merged"; return value is discarded by callers so branches silently accumulate

