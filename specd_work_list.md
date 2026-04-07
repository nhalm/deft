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

## orchestration v0.14

- Fix `setup_crash_decision_timeout` not checking `foreman_agent_restarting` flag: at line 2248, the crash notification prompt is sent via `Deft.Agent.prompt(data.foreman_agent_pid, ...)` without checking `data.foreman_agent_restarting`. Other ForemanAgent-bound messages (coalesced Lead messages at lines 1136/1185/1220, conflict notifications at line 1634) correctly check the flag. Fix: add `and not data.foreman_agent_restarting` guard — when the flag is true, buffer the crash notification and include it in the post-restart catch-up prompt.

