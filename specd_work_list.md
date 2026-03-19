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

## git-strategy v0.1

- Fix orphan cleanup to parse job_id from lead branch names: `branch_belongs_to_running_job?` (git/job.ex:700-703) preserves ALL `deft/lead-*` branches when any job is running; lead branch names contain the job_id (`deft/lead-<job_id>-<deliverable>`); should extract job_id prefix and check against `running_job_ids` so orphaned lead branches from prior crashed jobs are cleaned up

## issues v0.3

- Fix `elicitation_response_loop` tool event pattern mismatch: cli.ex:1574 listens for `{:tool_call, tool_name, _tool_id, args}` and cli.ex:1577 for `{:tool_result, _tool_id, result}`; agent broadcasts `{:tool_call_done, %{id: id, args: parsed_args}}` (agent.ex:808) and `{:tool_execution_complete, ...}` (agent.ex:1285); patterns never match; `draft_acc` stays nil; `handle_idle_state` always calls `handle_user_continuation` instead of presenting the draft; interactive issue creation is broken
