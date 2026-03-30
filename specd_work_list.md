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

- Add "Job complete" info-level log to `lib/deft/job/foreman.ex` `:complete` state entry handler: calculate duration since job start and total cost, log as `"#{log_prefix(data)} Job complete (#{duration_sec}s, $#{cost})"` — per §5 Info level "Job complete (duration, total cost)"
- Add periodic cost checkpoint info-level logging in `lib/deft/job/foreman.ex`: log accumulated cost at regular intervals during job execution as `"#{log_prefix(data)} Cost checkpoint: $#{cost}"` — per §5 Info level "Cost checkpoints (accumulated cost)"
