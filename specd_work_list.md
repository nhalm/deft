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

### CLI integration
- Update `lib/deft/cli.ex` — remove `alias Breeze.Server` and `@compile {:no_warn_undefined, Breeze.Terminal}`, replace Breeze startup in `execute_command(:new_session, ...)` and `execute_command({:resume_session, ...}, ...)` with starting `DeftWeb.Endpoint` (if not already running) and opening browser via `System.cmd("open", ["http://localhost:4000?session=<id>"])`. Print URL as fallback. Block until shutdown.

### Cleanup
- Delete `lib/deft/tui/` directory entirely (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex) after web UI is confirmed working (blocked: Update `lib/deft/cli.ex`...)

### Tests
- Create `test/deft_web/live/chat_live_test.exs` — tests for: mount renders header with repo name, text_delta event updates conversation, thinking_delta renders thinking block with styling, tool_call_start shows spinner, tool_call_done shows ✓/✗, Esc switches to normal mode, `i` in normal switches to insert, Enter submits prompt, slash command `/quit` handled, agent roster appears on job_status event, status bar shows token count and cost
- Create `test/deft_web/live/sessions_live_test.exs` — tests for: mount lists sessions, `j`/`k` navigation changes selected index, Enter redirects to chat with session_id
