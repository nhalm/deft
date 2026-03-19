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

- Spawn Foreman research/verification/merge-resolution Runners under the job supervision tree instead of `SessionWorker.tool_runner_via_tuple` (foreman.ex:508,1436): Runners on the session supervisor are not terminated when the job is aborted, causing orphaned LLM calls

## git-strategy v0.1

- Preserve merge-conflict temp worktree until merge-resolution Runner completes (git/job.ex:334): `cleanup_merge_worktree` runs unconditionally before `merge_lead_branch` returns `{:ok, :conflict, ...}`; the Foreman spawns a merge-resolution Runner pointing at `lead_info.worktree_path` which has no conflict markers; conflicts can never be resolved
- Add running-job check to `find_orphaned_branches` in orphan cleanup (git/job.ex:651-667): returns all `deft/*` branches unconditionally; if `cleanup_orphans` runs during an active job, it deletes branches belonging to the live job

## issues v0.3

- Fix cycle detection in `detect_and_fix_cycles` (issues.ex:553-580) to only clear dependencies of cycle members, not issues that point into the cycle (spec v0.3): current implementation marks issues as affected if they traverse to a cycle member, destroying valid dependency data; should only flag and clear dependencies for issues whose own ID appears in a cycle

## issues v0.2

- Send structured JSON to Foreman instead of Markdown in `build_issue_prompt` (cli.ex:2108-2121): spec section 6.1 requires structured JSON with `id`, `title`, `priority`, `context`, `acceptance_criteria`, `constraints`; code builds freeform Markdown text; `id` and `priority` are omitted entirely; Foreman cannot programmatically use `acceptance_criteria` as verification targets
- Remove duplicate prompt send in `run_work_on_issue` (cli.ex:2069,2081 + foreman.ex:267): `Foreman.start_link` stores prompt in initial data, and the `:enter` handler for `{:planning, :idle}` casts `{:prompt, data.prompt}` to self; then `Foreman.prompt(foreman_pid, issue_prompt)` sends it again; Foreman receives the same task description twice
