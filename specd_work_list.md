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

## web-ui v0.2

- Pass `key_arg` to `<.tool_call>` component in `chat_live.html.heex`: extract the primary argument from tool args (e.g., file path for `read`, command for `bash`) in the `:tool_call_done` handler and store it on the tool map, then pass it as `key_arg={tool.key_arg}`. Currently tools display only `[Tool: name]` without the key argument.
- Implement actual server shutdown in `handle_quit_command/1` at `chat_live.ex`: call `System.stop(0)` or `Application.stop(:deft)` instead of pushing an unhandled `"shutdown"` JS event. Currently `/quit` displays "Shutting down..." but the server keeps running.
