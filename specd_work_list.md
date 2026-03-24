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

## web-ui v0.4 + sessions v0.6

### Cleanup old TUI
- Delete `lib/deft/tui/` directory entirely (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex) — all functionality replaced by `lib/deft_web/`. Remove any remaining `Breeze` or `Termite` references from the codebase.

### Tests
- Verify all existing web UI tests still pass after changes — run `mix test test/deft_web/` and confirm 45+ tests, 0 failures. Run `mix test` for full suite. (blocked: Delete `lib/deft/tui/` directory...)
