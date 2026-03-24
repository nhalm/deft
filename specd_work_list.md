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

- Fix `dispatch_skill_or_command/3` to pass `args` to the agent: currently `_args` is discarded at `chat_live.ex:597`, so parameterized slash commands (`/model gpt-4`, `/forget <text>`, `/correct <old> -> <new>`, `/inspect <lead>`) silently lose their arguments. Either extend `Deft.Agent.inject_skill/2` to accept args, or send args as a follow-up user prompt after skill injection.
