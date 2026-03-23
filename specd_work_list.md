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

- Fix TUI job_status subscription: TUI registers `{:foreman, session_id}` in `Deft.ProcessRegistry` (chat.ex:42) which uses `keys: :unique` (application.ex:33); Foreman registers the same key first (foreman.ex:231), so TUI registration silently fails and never receives `{:job_status, ...}` broadcasts; switch to `Deft.Registry` (duplicate keys) or use a distinct key
- Fix thinking-only turns dropped from history: `commit_streaming_message` (chat.ex:734) guards on `current_text != ""` and discards `completed_thinking_blocks` + `current_thinking` when no text was produced; turns with thinking + tool calls but no text lose their thinking blocks from scrollback (violates spec §5.4)

