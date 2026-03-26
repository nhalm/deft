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

## logging v0.1

- Add DETS operation debug logs to `lib/deft/store.ex`: spec §9 requires DETS operations at debug level. `flush_buffer/2` and `open_dets_file/2` success paths have no debug logging.
- Add skill file parsing debug logs to `lib/deft/skills/registry.ex`: spec §9 requires skill file parsing at debug level. `parse_skill_manifest/2` and `discover_commands/3` have no debug logging during parse.

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
