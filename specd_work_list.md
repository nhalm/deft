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

- Fix `Agent.run/2` to log at warning level when `Store.append` fails (currently discards the return value with `_ = Store.append(...)`), respecting the "only callers log" principle
- Remove error-level logging from `Store.append/3` and `Store.append_to_path/2` in `lib/deft/session/store.ex:66` and `:94` (blocked: Agent must log append failures first)
