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

## issues v0.6

- Fix SIGINT handlers to return cost in abort tuple: `handle_job_result({:error, :sigint_shutdown}, ...)` (cli.ex:2308) and `handle_job_result({:error, :sigint_timeout}, ...)` (cli.ex:2331) return `{:error, :aborted}` (2-tuple) but the work loop (cli.ex:1988) only matches `{:error, :aborted, job_cost}` (3-tuple); the 2-tuple falls through to `handle_job_failure` which calls `exit({:shutdown, 1})` instead of stopping the loop gracefully

