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

## evals v0.4

- Fix `loop_safety_test.exs` stub: replace `run_loop_with_monitoring/2` with direct calls to CLI module functions (e.g., `Deft.CLI.execute_command/2`) or invoke the built escript via `System.cmd`; remove `:skip` tag once the real loop runs and produces meaningful data for safety assertions
