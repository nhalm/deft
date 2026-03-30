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
- Fix config key regression in `foreman.ex`: three `Map.get(data.config, ...)` calls use wrong keys — `:research_timeout` (line 210) should be `:job_research_timeout`, `:research_runner_model` (line 846) should be `:job_research_runner_model`, `:provider_name` (line 847) should be `:provider`. All configured values are silently ignored in favor of hardcoded defaults. Regression of v0.3 fix (specd_history). (blocked: Update Deft.Job.Supervisor to start ForemanAgent)
- Fix `--auto-approve-all` not skipping plan approval in `:decomposing` state: `foreman.ex:159-160` uses `auto_approve_all` only to skip `:asking` → `:planning`, but the `:decomposing` → `:executing` transition at line 479 waits for explicit `approve_plan` cast with no check for `auto_approve_all`. In `--auto-approve-all` or non-interactive mode, the job hangs in `:decomposing` forever. Spec section 3 and 4.1 require auto-approve to skip all plan approval gates. Regression of v0.3 implementation (specd_history line 423). (blocked: Update Deft.Job.Supervisor to start ForemanAgent)
- Add `{:foreman_contract, contract}` handler to Lead: `foreman.ex:380` sends `{:foreman_contract, contract}` to the Lead on `unblock_lead`, but `lead.ex` has no handler for this message — it hits the catch-all at line 458 and is silently discarded. The Lead must handle this message and forward the contract to its LeadAgent as a prompt so partial dependency unblocking actually works. Spec section 4.4 and 5.1. (blocked: Update Deft.Job.Lead.Supervisor to start LeadAgent)
- Fix Lead `:verifying` → `:complete` auto-transition ignoring test results: `lead.ex:387-388` transitions to `:complete` when the last runner finishes in `:verifying` regardless of pass/fail. The testing runner result is sent to the LeadAgent (line 381-383) but the transition happens immediately before the LeadAgent can evaluate or spawn corrective runners. Must inspect the Runner result — on failure, transition back to `:executing` so the LeadAgent can remediate; on success, transition to `:complete`. The `spawn_runner` handler (line 226-227) only fires in `:planning`/`:executing`, so corrective work is impossible from `:verifying`. Regression of v0.6 fix (specd_history). (blocked: Update Deft.Job.Lead.Supervisor to start LeadAgent)
