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

## git-strategy v0.2

- Implement `abort_job/1` for failure cleanup (git/job.ex): spec Section 5 requires removing Lead worktrees, deleting the job branch (respecting `keep_failed_branches` config), and restoring the original branch; no abort/failure cleanup function exists; `keep_failed_branches` config is never read

## issues v0.5

- Fix double `get_job_cost` in abort path (cli.ex:2118,2345): `run_work_on_issue` calls `get_job_cost(job_id)` at line 2118 which stops the RateLimiter; then `handle_job_result({:error, :aborted}, ...)` calls `get_job_cost(job_id)` again at line 2345; the second call finds a dead process and returns 0.0; aborted jobs always report "$0.00" cost to the user
