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

## web-ui v0.1

- Fix LiveSocket metadata callbacks: `app.js` initializes `LiveSocket` without `metadata` config, so `phx-window-keydown` events never include `ctrlKey`. All Ctrl+ key handlers (Ctrl+b tmux prefix, Ctrl+c abort, Ctrl+l clear) are unreachable dead code. Add `metadata: {keydown: (e) => ({ctrlKey: e.ctrlKey})}` to `LiveSocket` constructor in `assets/js/app.js`.
- Fix `status_icon/1` type mismatch in `tool_call.ex`: `status_icon(@status)` passes an atom (`:running`, `:success`, `:error`) but function heads match on maps (`%{status: :running}`). The specific clauses never match — spinner, ✓, and ✗ icons never render. Change function heads to match atoms, or wrap the call as `status_icon(%{status: @status})`.
- Fix `format_datetime/1` crash on nil in `sessions_live.ex`: `Calendar.strftime(nil, ...)` raises `FunctionClauseError` if any session has `nil` `last_message_at`. Add a `format_datetime(nil)` clause returning a fallback string like `"—"`.
