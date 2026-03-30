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

- Fix `collect_research_results`: replace sequential `Enum.map` + `Task.yield` with `Task.yield_many/2` — Foreman currently blocks for up to N×timeout and is completely unresponsive to user commands, Lead crashes, and cost warnings during research collection (foreman.ex:1159-1167)
- Fix `do_abort_lead`: add aborted Lead to `completed_leads` (or new tracking set) and update `all_leads_complete?` to account for aborted Leads — currently using `abort_lead` tool causes the job to hang in `:executing` forever because aborted Leads are removed from `started_leads` but never counted toward completion (foreman.ex:1003-1019, 1029-1042)

## orchestration v0.9

- Add `failed_leads` set to Foreman state (alongside `started_leads` and `completed_leads`) to track Leads removed due to crash or explicit failure
- Add `fail_deliverable` orchestration tool: ForemanAgent can call it when a Lead crashes to decide whether to skip the deliverable or retry with a fresh Lead. Tool sends message to Foreman which moves Lead from started_leads to failed_leads.
- Update `all_leads_complete?` to return true when `completed_leads + failed_leads == total_leads` (currently only checks completed_leads, causing hangs when Leads crash)
- Update `do_handle_lead_crash` to send crash notification to ForemanAgent via prompt (so agent can decide via `fail_deliverable` tool) instead of silently removing from tracking

## orchestration v0.8

- Add ForemanAgent monitoring: call `Process.monitor` on ForemanAgent PID (on `{:set_foreman_agent, pid}` cast), handle `:DOWN` in `handle_event(:info, ...)` by failing the job with full cleanup — currently ForemanAgent crash leaves Foreman with stale PID, all prompts silently fail, job hangs permanently (foreman.ex:278-280, 604-613)

