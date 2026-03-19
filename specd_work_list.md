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

## orchestration v0.3

- Implement `process_provider_event/2` in Lead to accumulate streaming text and tool calls (lead.ex:723-726): same no-op placeholder as Foreman; Lead cannot process LLM responses for task decomposition or steering
- Implement `finalize_streaming/1` in Lead to build complete assistant message from stream (lead.ex:733-740): same placeholder as Foreman
- Implement `add_tool_results/2` in Lead to inject tool results into messages (lead.ex:742-746): same placeholder as Foreman

