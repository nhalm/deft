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

- Implement Lead→LeadAgent prompt flow: Lead calls `Deft.Agent.prompt/2` with deliverable assignment, Runner results, and Foreman steering (blocked: Create Deft.Job.Lead, Create Deft.Job.LeadAgent)
- Update `Deft.Job.Supervisor` to start ForemanAgent + its ToolRunner as separate children alongside the Foreman (blocked: Create Deft.Job.ForemanAgent)
- Update `Deft.Job.Lead.Supervisor` to start LeadAgent + its ToolRunner as separate children alongside the Lead (blocked: Create Deft.Job.LeadAgent)
- Implement single-agent fallback: when Foreman detects simple task, configure ForemanAgent with full tool set (read, write, edit, bash, grep, find, ls) and skip orchestration (blocked: Implement Foreman→ForemanAgent prompt flow)
- Remove old tuple-state Foreman implementation (the fused orchestrator+agent gen_statem) and replace with new split architecture (blocked: all above items)
- Remove old tuple-state Lead implementation and replace with new split architecture (blocked: all above items)

