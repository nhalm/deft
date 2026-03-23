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

## tui v0.4

- Fix `/correct` misroute during orchestration (chat.ex:964): `String.contains?(message, "→")` only checks for Unicode arrow; the spec's primary syntax `->` (ASCII) is not checked, so `/correct old -> new` is misrouted as a job correction when a job is active; must check for both `->` and `→`