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
- Implement single-agent fallback: when Foreman detects simple task, configure ForemanAgent with full tool set (read, write, edit, bash, grep, find, ls) and skip orchestration (blocked: Implement Foreman→ForemanAgent prompt flow)
- Remove old tuple-state Foreman implementation (the fused orchestrator+agent gen_statem) and replace with new split architecture (blocked: all above items)
- Remove old tuple-state Lead implementation and replace with new split architecture (blocked: all above items)
- Fix Foreman site log writes to use correct `Store.write/4` API (foreman.ex:519-523): currently calls `Store.write(pid, key, %{content: content, metadata: metadata, timestamp: ...})` which stores a nested map as `entry.value` and leaves `entry.metadata` as `%{}`; should call `Store.write(pid, key, content, %{category: type, ...metadata})` so `entry.value` is the raw content string and metadata is properly stored
- Add `Process.monitor/1` call when spawning Leads (foreman.ex:337-365): the spawn_lead handler tracks leads in `data.leads` but never calls `Process.monitor`; `lead_monitors` map stays empty; the DOWN handler at line 530 never matches; Lead crashes are silently ignored. Regression of v0.3 fix.
- Add Runner timeout enforcement in Lead (lead.ex:184-192): after spawning a Runner via `Task.Supervisor.async_nolink`, call `Process.send_after(self(), {:runner_timeout, task.ref}, timeout)` using `runner_timeout` config; add a `:runner_timeout` handler that kills timed-out Runners. Currently no timeout is enforced — a hung Runner blocks the Lead indefinitely. Regression of v0.3 fix.
- Fix Lead test functions not exported: tests call `Lead.spawn_runner/5` (lead_test.exs:104) and `Lead.send_lead_message/4` (lead_test.exs:291,325,359,393) which don't exist as public functions in the v0.7 Lead module; tests fail with UndefinedFunctionError. Either add public API wrappers or update tests to use message passing directly.

