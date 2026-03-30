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

- Fix `Deft.Job.Lead.Supervisor` to start LeadAgent via `Deft.Job.LeadAgent.start_link/1` instead of `Deft.Agent.start_link/1` — same issue, LeadAgent has no Lead-specific tools or OM
- Handle `{:agent_action, :plan, plan_data}` in `:planning` state (not just `:researching`) — after plan rejection the Foreman returns to `:planning`, and if the ForemanAgent resubmits a plan without calling `request_research` first, the message is silently dropped and the job hangs
- Handle `{:lead_message, :complete, ...}` by removing Lead from `started_leads` and checking `all_leads_complete?` for transition to `:verifying` — currently the normal completion path never transitions to `:verifying` (only the crash path does)
