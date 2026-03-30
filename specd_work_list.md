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

## logging v0.5

- Disable Phoenix built-in LiveView callback logging: change `log: :debug` to `log: false` in the `live_view` macro in `lib/deft_web.ex`
- Remove `Logger.debug("[Chat:...] Event: keydown")` from the `handle_event("keydown", ...)` clause in `lib/deft_web/live/chat_live.ex` — delete the log line only, keep the handler logic
- Move "Session loaded" log out of `Store.load/2` in `lib/deft/session/store.ex`: remove the `Logger.info` from `load/2`, add `Logger.info("[Session] Session resumed: #{session_id}, #{length(entries)} entries")` in `resume/2` after a successful load. This stops `list_sessions` from spamming on startup.