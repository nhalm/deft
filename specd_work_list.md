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

- Fix Lead crash falsely satisfying `all_leads_complete?`: when a Lead crashes (foreman.ex:1059-1098), it is removed from `data.leads` but remains in `data.started_leads`; `all_leads_complete?` checks `started_count == deliverables_count and remaining_leads == 0`, which is satisfied even though the crashed Lead's deliverable is incomplete; Foreman transitions to `:verifying` with missing work; either track failed deliverables separately or check that all started deliverables have a corresponding merge/completion record
