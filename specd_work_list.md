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

- Make `run_post_merge_tests` asynchronous in Foreman: `process_lead_message(:complete, ...)` at foreman.ex:1802 synchronously calls `handle_lead_merge` → `handle_successful_merge` → `run_post_merge_tests` → `GitJob.run_post_merge_tests` which uses `Task.yield(task, 300_000)`, blocking the gen_statem for up to 5 minutes. Spawn the test task and handle the result via a message handler (like the research timeout pattern) so the Foreman remains responsive to other Lead messages and DOWN signals.
- Implement `send_user_message/2` in Foreman: the stub at foreman.ex:3217 only logs messages. Verification failures (line 1139) and merge errors after verification (line 1094) silently disappear — the user never learns the job outcome. Wire this to the TUI/session so job results are delivered to the user.
