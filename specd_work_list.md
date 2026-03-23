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

### Agent roster
- Render agent roster as right-aligned text rows in the top-right of the conversation area — one row per agent (Foreman, each Lead, Runners) with `◉ <state>` indicator
- Color the `◉` indicator by state: green (planning, researching, executing, implementing, testing, merging, verifying), yellow (waiting), white (idle, complete), red (error) (blocked: Render agent roster as right-aligned text rows in the top-right of the conversation area)
- Collapse multiple active Runners into a single `Runners (N)` row instead of listing each individually (blocked: Render agent roster as right-aligned text rows in the top-right of the conversation area)
- Hide agent roster in solo mode; only render when a Job is active (blocked: Render agent roster as right-aligned text rows in the top-right of the conversation area)
- Wrap conversation text to avoid the roster area (~30 rightmost columns) during orchestration; collapse roster to header-only when terminal width < 80 columns (blocked: Render agent roster as right-aligned text rows in the top-right of the conversation area)
