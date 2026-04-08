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

## web-ui v0.6

- Replace header buttons: remove the three emoji-only `<button>` tags in `.header-right`. Replace with an `<a href="/sessions" target="_blank" class="header-button">Sessions</a>` link and a `<button class="header-button" phx-click="show_help">Help</button>` (blocked: Fix header-button CSS)
- Fix `.header-button` CSS: set `font-size: 13px`, `padding: 6px 12px`, `color: var(--text-secondary)`, visible border, hover state. Remove the settings button (no settings page exists)
- Add `.session-item.selected` CSS in `app.css`: distinct background color (e.g., `var(--bg-tertiary)` or `rgba(255,255,255,0.08)`) so keyboard selection is visible
- Add `phx-click="select_session"` with `phx-value-index` to each `.session-item` div in SessionsLive, with a `handle_event("select_session", ...)` that opens the session in a new tab via a JS hook or `push_event`
- Change SessionsLive Enter handler: replace `push_navigate(socket, to: "/?session=...")` with `push_event(socket, "open_session", %{url: "/?session=..."})` and add a JS hook that calls `window.open(url, "_blank")` (blocked: Add phx-click select_session)
- Add JS hook `OpenSession` in `app.js` that listens for `open_session` push events and calls `window.open(url, "_blank")`

