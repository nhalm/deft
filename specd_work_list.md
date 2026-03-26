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

## logging v0.1

- Add error-level log for tool crashes in `lib/deft/agent/tool_runner.ex`: spec §4 requires `Tool crashes (tool name, reason)` at `:error` level. The `{:exit, reason}` branch in `execute_batch/5` silently returns an error tuple — add `Logger.error` with tool name and crash reason.
- Add `:info` logs for session loaded/saved in `lib/deft/session/store.ex`: spec §9 requires info-level logs for session load and save operations. Currently only has `:error` and `:debug` logs.
- Add `:info` log for issue created/updated in `lib/deft/issues.ex`: spec §9 requires info-level logs when issues are created or updated. Currently only logs compaction at `:info`.
- Add `:info` log for skill registered in `lib/deft/skills/registry.ex`: spec §9 requires info-level log when skills are registered. Currently only has `:warning` logs.
- Change Observer triggered log from `:debug` to `:info` in `lib/deft/om/state.ex` `spawn_observer_task/2`: spec §7 requires "Observer triggered (observation count)" at `:info`. Add observation count to message.
- Change Reflector triggered log from `:debug` to `:info` in `lib/deft/om/state.ex` `spawn_reflector_task/1`: spec §7 requires "Reflector triggered (compression ratio)" at `:info`. Add compression ratio to message.
- Change snapshot persisted log from `:debug` to `:info` in `lib/deft/om/state.ex` `write_snapshot/1`: spec §7 requires "Snapshot persisted" at `:info`.
