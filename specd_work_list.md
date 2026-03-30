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

## logging v0.6

- Fix `log_tool_crashes/2` in `lib/deft/agent.ex:1557-1566` to also match `"Tool execution error: " <> reason`: currently only matches `"Tool crashed: "` prefix (process exit path), but rescued exceptions in `execute_tool` return `"Tool execution error: ..."` which silently passes through without error-level logging — spec §4 requires all tool crashes logged at error level
- Fix `complete_turn_and_transition_idle/1` in `lib/deft/agent.ex:1268` to log the actual source state instead of hardcoded `"executing_tools -> idle"`: `handle_idle_transition` is called from `:calling`, `:streaming`, and `:executing_tools` states, but the debug log always says `executing_tools -> idle` — spec §4 requires accurate state transitions at debug level
