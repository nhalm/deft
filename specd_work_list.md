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

## tui v0.3

- Fix roster right-alignment padding: `render_agent_roster` (chat.ex:1647) uses `String.length(roster_line)` which counts ANSI escape code codepoints as visible characters; `"\e[32m◉\e[39m"` is 10 codepoints but 1 terminal column, so every roster line is displaced ~9 columns left of intended position; strip ANSI codes before measuring length or use a display-width-aware measurement

