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

- Fix Lead `spawn_runner` to build a proper `runner_config` with `provider: get_provider(data)` (module) instead of passing `data.config` directly — `data.config[:provider]` is a string like `"anthropic"`, but Runner calls `provider.stream(...)` expecting a module, causing `UndefinedFunctionError` at runtime
- Fix Lead verification phase to spawn a testing Runner instead of prompting itself — the Lead enters `{:verifying, :idle}` and sends a `:prompt` to its own LLM with instructions to "run compile checks" and "run tests", but the Lead's tool set is read-only `[Read, Grep, Find, Ls]` and cannot execute anything; spec v0.4 explicitly requires spawning a testing Runner
- Add DOWN handler for research runner crashes in Foreman — `Process.monitor(task.pid)` at foreman.ex:335 creates a monitor ref distinct from `task.ref`, but the only DOWN handler (foreman.ex:684) checks `tool_tasks` not `research_tasks`; crashed research runners are never cleaned up, hanging the research phase until the 120s timeout
