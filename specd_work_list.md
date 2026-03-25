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

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)

## web-ui v0.5

- Flush completed tools to the conversation stream immediately on `:tool_execution_complete`. Currently tools live in `active_tools` and only clear on `:idle`.
- Update the template to render conversation stream items by type — dispatch to the thinking component, a text/markdown block, or the tool component based on the item's type field.
- Auto-collapse thinking blocks once they finish streaming. Thinking should be expanded while actively streaming, then collapse when it persists to the conversation. User can click to re-expand.
- Update the `:idle` handler to only flush remaining in-progress content (if any), not the entire turn. Most content will already be persisted by earlier incremental flushes.
