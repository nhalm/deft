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

## logging v0.2

- Add error-level logging for job abort cleanup failures in foreman.ex and git/job.ex: spec v0.2 §6 requires "Job abort cleanup failures" at Error level (blocked: need to identify where cleanup failures occur and add error handling)

## logging v0.1

- Change branch operation success logs from `:info` to `:debug` in `lib/deft/git/job.ex`: spec §6 requires "Branch operations (create, merge, cleanup)" at `:debug`. Applies to success paths (lines 1004, 1017, and similar); failure paths correctly stay at `:error`

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
