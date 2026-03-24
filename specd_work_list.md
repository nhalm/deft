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

### Verify `mix deft` works end-to-end
- Run `mix deft` and confirm: (1) OTP app starts including Endpoint, (2) browser opens to `http://localhost:4000`, (3) web UI renders the chat interface, (4) Ctrl+C shuts down cleanly. Then test `mix deft -p "hello"` for non-interactive mode.

### Verify `mix deft work` and `mix deft issue` subcommands
- Run `mix deft issue list` and confirm it dispatches correctly through `Deft.CLI.main(["issue", "list"])`. Run `mix deft work` and confirm it dispatches to the work loop. These already work in cli.ex — just verify the Mix task wrapper passes args through correctly. (blocked: Verify `mix deft` works end-to-end...)

### Syntax highlighting
- Add highlight.js to `assets/js/app.js` — import from CDN or vendor bundle, call `hljs.highlightAll()` after each LiveView DOM update via a `phx-hook` on the conversation container. Style code blocks with a dark theme.

### Cleanup old TUI
- Delete `lib/deft/tui/` directory entirely (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex) — all functionality replaced by `lib/deft_web/`. Remove any remaining `Breeze` or `Termite` references from the codebase. (blocked: Verify `mix deft work` and `mix deft issue`...)

### Tests
- Verify all existing web UI tests still pass after changes — run `mix test test/deft_web/` and confirm 45+ tests, 0 failures. Run `mix test` for full suite. (blocked: Delete `lib/deft/tui/` directory...)
