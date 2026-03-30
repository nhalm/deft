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

## orchestration v0.7

- Fix Lead `:verifying` → `:complete` auto-transition ignoring test results: `lead.ex:387-388` transitions to `:complete` when the last runner finishes in `:verifying` regardless of pass/fail. The testing runner result is sent to the LeadAgent (line 381-383) but the transition happens immediately before the LeadAgent can evaluate or spawn corrective runners. Must inspect the Runner result — on failure, transition back to `:executing` so the LeadAgent can remediate; on success, transition to `:complete`.
