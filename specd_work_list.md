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

## sessions v0.6

- Defer `ANTHROPIC_API_KEY` validation from `config/runtime.exs` to LLM-using CLI commands: Remove the fail-fast check from runtime.exs (currently at lines 13-19) and add it instead to code paths that actually call the LLM (e.g., `start_web_ui`, `non_interactive_mode`, `work` commands). This allows non-LLM commands like `deft --help`, `deft --version`, `deft config`, and `deft issue list` to work without an API key configured (spec §5.2).

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex:392-396: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
