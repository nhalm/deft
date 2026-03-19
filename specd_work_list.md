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

## orchestration v0.4

- Add verification Runner timeout in Foreman `start_verification` — use `job_runner_timeout` config (default 300_000ms) with `Process.send_after` and a handler to fail the job on timeout, matching the pattern used by `research_timeout`
- Add `job.max_duration` enforcement in Foreman — set a job-level timer on init using `job_max_duration` config (default 1_800_000ms), handle timeout by aborting the job with cleanup
