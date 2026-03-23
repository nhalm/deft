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

- Fix `phx-window="true"` on chat container: `chat_live.html.heex` line 1 uses `phx-keydown="keydown" phx-window="true"` — `phx-window` is not a valid LiveView attribute. Change to `phx-window-keydown="keydown"` so keyboard events fire at the window level.
- Add `handle_info` clause for `{:agent_event, {:error, reason}}` in `ChatLive` — currently caught by the catch-all and silently dropped. Display error message in conversation stream.
- Increment `turn_count` in `ChatLive` — initialized to 0 but never updated. Increment on each `:usage` event so the status bar shows the correct turn number.
- Replace `<input type="text">` with `<textarea>` in `chat_live.html.heex` for multi-line input support (Shift+Enter for newline, Enter to submit per spec §4).
- Add collapsible thinking blocks: inline thinking template in `chat_live.html.heex` has no click-to-collapse. Either use the existing `DeftWeb.Components.Thinking` component (which has `phx-click="toggle_thinking"`) or add collapse logic inline, and add corresponding `handle_event("toggle_thinking", ...)` in `ChatLive`.
- Add expandable tool calls: inline tool template in `chat_live.html.heex` has no click-to-expand details. Either use the existing `DeftWeb.Components.ToolCall` component or add expand logic inline, and add corresponding `handle_event("toggle_tool", ...)` in `ChatLive`. (blocked: collapsible thinking blocks)
- Add tmux pane keys `x` (close active panel), `h`/`l` (focus left/right pane) to `handle_tmux_key/2` in `ChatLive` — currently only `%` and `z` are handled.
- Add global keys `Ctrl+c` (abort agent operation) and `Ctrl+l` (clear/redraw) to `handle_standard_vim_key/3` in `ChatLive`. Include double-`Ctrl+c` tracking for force abort per spec §6.4.
- Add input history: track submitted prompts in a history buffer assign, handle Up/Down arrow keys in normal mode to navigate history per spec §4.
- Fix orchestration status bar: currently shows `X agents`, spec requires `X leads │ Y/Z complete │ $cost/$budget │ Xm elapsed │ ◉ state`. Compute lead count and completion from `@agent_statuses`.
