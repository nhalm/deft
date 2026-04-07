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

## orchestration v0.16

- Add `foreman_agent_restarting` guard to the `:flush_lead_messages` timer handler in `foreman.ex`. When `data.foreman_agent_restarting` is true, the handler must be a no-op (`:keep_state_and_data`) — do not send to ForemanAgent, do not clear the buffer. The buffer contents will be included in the restart catch-up prompt. Add test: set a debounce timer, crash ForemanAgent, verify the timer firing does not clear the buffer or raise.

