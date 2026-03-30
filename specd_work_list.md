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

- Fix `submit_plan` handler type mismatch: `submit_plan.ex` sends `{:agent_action, :plan, %{deliverables: list, dependencies: list, rationale: string}}` but `foreman.ex:322` binds the map to `deliverables` and calls `length(deliverables)` which crashes on a map. Either destructure the map in the handler or send just the deliverables list. (blocked: Update Deft.Job.Supervisor to start ForemanAgent)
- Implement Lead→LeadAgent prompt flow: Lead calls `Deft.Agent.prompt/2` with deliverable assignment, Runner results, and Foreman steering (blocked: Create Deft.Job.Lead, Create Deft.Job.LeadAgent)
- Update `Deft.Job.Supervisor` to start ForemanAgent + its ToolRunner as separate children alongside the Foreman (blocked: Create Deft.Job.ForemanAgent)
- Update `Deft.Job.Lead.Supervisor` to start LeadAgent + its ToolRunner as separate children alongside the Lead (blocked: Create Deft.Job.LeadAgent)
- Implement Lead crash recovery in Foreman `:DOWN` handler (foreman.ex:534-540): the handler is a TODO stub that returns `:keep_state_and_data`. Must clean up the crashed Lead's worktree, remove Lead from tracking state (`data.leads`, `lead_monitors`, `started_leads`), and check `all_leads_complete?` for phase transition — otherwise job hangs in `:executing` if last Lead crashes. `do_abort_lead` has partial cleanup logic to reuse. (blocked: Update Deft.Job.Lead.Supervisor to start LeadAgent)
- Implement single-agent fallback: when Foreman detects simple task, configure ForemanAgent with full tool set (read, write, edit, bash, grep, find, ls) and skip orchestration (blocked: Implement Foreman→ForemanAgent prompt flow)
- Remove old tuple-state Foreman implementation (the fused orchestrator+agent gen_statem) and replace with new split architecture (blocked: all above items)
- Remove old tuple-state Lead implementation and replace with new split architecture (blocked: all above items)
- Fix `spawn_lead` tool data loss: `spawn_lead.ex:45-48` sends only `%{id: deliverable_id, context: context}`, dropping `name`, `description`, `files`, `estimated_complexity` from the plan. Foreman at `foreman.ex:350` accesses `deliverable[:name]` → nil. Lead receives no useful deliverable info for planning. Either pass through the full deliverable from the approved plan, or have the Foreman look up the deliverable from `data.plan` by ID when handling `{:agent_action, :spawn_lead, ...}`.
- Fix config key regression in `foreman.ex`: three `Map.get(data.config, ...)` calls use wrong keys — `:research_timeout` (line 210) should be `:job_research_timeout`, `:research_runner_model` (line 846) should be `:job_research_runner_model`, `:provider_name` (line 847) should be `:provider`. All configured values are silently ignored in favor of hardcoded defaults. Regression of v0.3 fix (specd_history). (blocked: Update Deft.Job.Supervisor to start ForemanAgent)

