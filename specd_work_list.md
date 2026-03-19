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

## orchestration v0.4

- Fix Lead `execute_tool/2` to return `{tool_call.id, result}` tuple instead of bare `{:ok, content}` or `{:error, reason}`: `build_tool_result_blocks/2` (lead.ex:1004) pattern-matches `{tool_use_id, tool_result}` but `execute_tool` returns `{:ok, content}`, so `:ok` becomes the `tool_use_id` in the ToolResult block; Anthropic API rejects the malformed tool results, breaking the Lead's tool execution cycle
- Fix Foreman lead message handler to transition to `{new_phase, :idle}` instead of `{new_phase, agent_state}`: foreman.ex:653 preserves the current `agent_state` on phase transition, but the `:verifying` enter handler (foreman.ex:388) and `:start_verification` cast handler (foreman.ex:505) only match `{:verifying, :idle}`; if the last Lead completes while Foreman is in `:calling`/`:streaming`, verification never starts and the job hangs
