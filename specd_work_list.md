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

## web-ui v0.2

- Fix `scroll_offset` atom crash after `G` key in `chat_live.ex`: pressing `G` assigns `:bottom` (atom) to `scroll_offset` at line 561, but `j`/`k`/`Ctrl+u`/`Ctrl+d` handlers (lines 547, 554, 578, 585) do integer arithmetic on it (`scroll_offset + 1`, `max(0, scroll_offset - 1)`, etc.), causing `ArithmeticError`. Either assign `0` instead of `:bottom` after `G`, or guard arithmetic clauses to reset `:bottom` to a numeric value first.
