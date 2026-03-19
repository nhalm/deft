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

## orchestration v0.3

- Handle verification Runner crash in Foreman: add a DOWN handler or task-ref-based crash handler for verification tasks stored in `data.tool_tasks`; currently if the verification Runner crashes, the `{:DOWN, ref, ...}` message hits the Lead crash handler (foreman.ex:654) which doesn't match and returns `:keep_state_and_data`; job hangs in `:verifying` permanently
- Call `check_phase_transition` after Lead crash in Foreman DOWN handler (foreman.ex:680-686): after removing the crashed Lead from `data.leads`, check if `all_leads_complete?` is now true and transition to `:verifying` if so; currently returns `{:keep_state, data}` unconditionally, causing the job to hang in `:executing` if the last Lead crashes
- Handle Lead start failure in Foreman `start_lead/2` (foreman.ex:2518-2525): when `LeadSupervisor.start_lead` or worktree creation fails, the deliverable name is never added to `started_leads`; `all_leads_complete?` requires `started_count == deliverables_count` which can never be satisfied; either add the deliverable to `started_leads` on failure (so the count matches) or use a different completion check that accounts for failed starts

## issues v0.4

- Add fallback clauses to `normalize_status/1` and `normalize_source/1` in Issue (issue.ex:134-142): unrecognized string values (e.g., from a bad git merge) raise `FunctionClauseError` which propagates through `decode/1` and crashes `Issues.init/1`; add `defp normalize_status(_), do: :open` and `defp normalize_source(_), do: :user` with a Logger.warning
- Wire CLI plan approval flow for `deft work`: `wait_for_job_completion/2` (cli.ex:2136-2180) has no mechanism to detect when the Foreman is waiting for plan approval in `{:decomposing, :idle}` state; add a message-based protocol (e.g., Foreman sends `{:plan_approval_needed, plan}` to a registered CLI process) so the CLI can display the plan and call `Foreman.approve_plan/1`; without `--auto-approve-all`, the Foreman hangs in decomposing indefinitely
