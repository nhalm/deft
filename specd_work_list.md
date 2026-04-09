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

## logging v0.7

- Remove all per-event `Logger.debug` calls in `lib/deft/agent.ex`: "SSE event received" (14 lines) and "Broadcasting event" (1 line) — delete the Logger.debug lines, keep the surrounding event-handling logic
- Remove all per-event `Logger.debug` calls in `lib/deft_web/live/chat_live.ex`: "Agent event received" (9 lines) — delete the Logger.debug lines, keep the event handlers
