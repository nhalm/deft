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

## issues v0.2

- Send structured JSON to Foreman instead of Markdown in `build_issue_prompt` (cli.ex:2108-2121): spec section 6.1 requires structured JSON with `id`, `title`, `priority`, `context`, `acceptance_criteria`, `constraints`; code builds freeform Markdown text; `id` and `priority` are omitted entirely; Foreman cannot programmatically use `acceptance_criteria` as verification targets
- Remove duplicate prompt send in `run_work_on_issue` (cli.ex:2069,2081 + foreman.ex:267): `Foreman.start_link` stores prompt in initial data, and the `:enter` handler for `{:planning, :idle}` casts `{:prompt, data.prompt}` to self; then `Foreman.prompt(foreman_pid, issue_prompt)` sends it again; Foreman receives the same task description twice
