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

## issues v0.4

- Wire CLI plan approval flow for `deft work`: `wait_for_job_completion/2` (cli.ex:2136-2180) has no mechanism to detect when the Foreman is waiting for plan approval in `{:decomposing, :idle}` state; add a message-based protocol (e.g., Foreman sends `{:plan_approval_needed, plan}` to a registered CLI process) so the CLI can display the plan and call `Foreman.approve_plan/1`; without `--auto-approve-all`, the Foreman hangs in decomposing indefinitely
