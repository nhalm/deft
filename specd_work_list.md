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

## logging v0.6

- Validate `LOG_LEVEL` env var in `config/runtime.exs`: reject values outside `debug | info | warning | error` with a clear error message instead of passing arbitrary atoms to Logger (which crashes on invalid levels)
- Add warning-level logging for individual calling errors during retry in `lib/deft/agent.ex` `handle_calling_error/2`: currently retries 1-2 emit zero log output — log the error reason and retry count at warning level before scheduling retry
- Add debug-level logging for branch operations in `lib/deft/job/foreman.ex`: log before `create_lead_worktree` and `cleanup_lead_worktree` calls (spec §5 requires "Branch operations (create, merge, cleanup)" at debug level)
