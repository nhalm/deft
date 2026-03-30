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

## logging v0.6

- Move tool crash logging from `ToolRunner` to the Agent layer: remove `Logger.error` from `lib/deft/agent/tool_runner.ex:103-105` (`log_tool_crash/3`), and add error-level logging with `[Agent:<id>]` prefix in the Agent's tool result handler when a tool crash result is received — per §4 Error level and the "only callers log" principle
- Add job description (prompt) to "Job started" log in `lib/deft/job/foreman.ex:144`: change to include `data.prompt` so the log reads "Foreman started for job #{session_id}: #{prompt}" — per §5 Info level "Job started (job ID, description)"
- Add task summary to "Lead spawned" log in `lib/deft/job/foreman.ex:1088-1090`: include `deliverable[:name]` in the log message — per §5 Info level "Lead spawned/completed (lead ID, task summary)"
- Add task summary to "Lead completed" log in `lib/deft/job/foreman.ex:1205`: include the deliverable name from `data.leads[lead_id].deliverable[:name]` — per §5 Info level "Lead spawned/completed (lead ID, task summary)"
