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

## orchestration v0.7

- Fix `parent_pid` passed to ForemanAgent and LeadAgent — `Job.Supervisor` (line 123) passes `parent_pid: foreman_name` where `foreman_name` is a `{:via, Registry, ...}` tuple, but all ForemanAgent tools (`submit_plan`, `ready_to_plan`, `request_research`, `spawn_lead`, `abort_lead`, `steer_lead`, `unblock_lead`) guard `when is_pid(parent_pid)` causing `FunctionClauseError` on every tool call. Same issue in `Lead.Supervisor` (line 81) for LeadAgent tools (`spawn_runner`, `publish_contract`, `report_status`, `request_help`). Fix: resolve the via-tuple to a PID before passing as `parent_pid`, or use `GenServer.whereis/1` in the supervisor after the Foreman/Lead process starts.

