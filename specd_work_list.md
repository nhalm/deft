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

### Breeze startup integration
- Wire up `deft resume` (no session ID) to start Breeze with `Deft.TUI.SessionPicker` — when the user selects a session, the picker returns the session ID, then CLI reconstructs that session and starts a new Breeze server with `Deft.TUI.Chat`

### Shutdown and terminal safety
- Add `try/catch` wrapper around the Breeze server call in CLI to guarantee terminal restoration on crash — catch `:exit` reason, call `Breeze.Terminal.restore/0` if available, otherwise emit raw ANSI reset sequences (`\e[?1049l`, `\e[?25h`, `\e[0m`)
- Implement double Ctrl+C behavior in `Deft.TUI.Chat`: first press while agent is working sends abort to Agent and stays open; second press (or first press while idle) returns `{:stop, term}` to exit Breeze
