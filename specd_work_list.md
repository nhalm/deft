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

## orchestration v0.8

- Add ForemanAgent monitoring: call `Process.monitor` on ForemanAgent PID (on `{:set_foreman_agent, pid}` cast), handle `:DOWN` in `handle_event(:info, ...)` by failing the job with full cleanup — currently ForemanAgent crash leaves Foreman with stale PID, all prompts silently fail, job hangs permanently (foreman.ex:278-280, 604-613)

