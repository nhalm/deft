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

## orchestration v0.10

### Process lifecycle correctness

- Fix `fail_deliverable` handler: after adding lead_id to `failed_leads` and removing from `started_leads`, also remove the entry from `data.leads` map. Currently the stale entry remains, causing misleading Lead status in ForemanAgent prompts.
- Fix `do_abort_lead`: change `MapSet.put(&1, lead_id)` on `completed_leads` to `MapSet.put(&1, lead_id)` on `failed_leads`. Aborted Leads are not successfully completed — they should count as failed per the spec's `all_leads_complete?` semantics.
- Fix DOWN handler (`handle_event(:info, {:DOWN, ...})`): check `reason` before dispatching. For ForemanAgent: only call `do_fail_job_on_foreman_agent_crash` if reason is NOT `:normal` or `:shutdown`/`{:shutdown, _}`. For Leads: only call `do_handle_lead_crash` if reason is NOT `:normal` or `:shutdown`/`{:shutdown, _}`. Normal/shutdown exits should be logged and ignored (the completion path handles them).
- Fix `do_fail_job_on_foreman_agent_crash`: before returning `{:stop, ...}`, iterate `data.lead_monitors` and call `Process.demonitor(ref, [:flush])` for each. This prevents the gen_statem from processing spurious Lead DOWN messages during its shutdown sequence, which currently causes double worktree cleanup.
- Fix `set_foreman_agent` cast handler: before calling `Process.monitor(pid)`, check if `data.foreman_agent_monitor_ref` is non-nil and call `Process.demonitor(old_ref, [:flush])`. Prevents double-monitoring and leaked monitor refs.

### Sibling process resilience

- Replace cached `rate_limiter_pid` in Foreman state with a registered name lookup function: define a private `rate_limiter_pid/1` helper that does `GenServer.whereis({:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}})`. Replace all `data.rate_limiter_pid` reads with calls to this helper. Remove `rate_limiter_pid` from the initial data map. (blocked: Verify RateLimiter registers under this name in ProcessRegistry)
- Replace cached `site_log_pid` in Foreman state with the registered name on each use: use `{:via, Registry, {Deft.ProcessRegistry, {:sitelog, data.session_id}}}` directly in Store calls instead of `data.site_log_pid`. Remove `site_log_pid` from initial data map and the `resolve_site_log_pid/1` init helper.

### Code-speed orchestration: contract auto-unblocking

- Add `match_contract_to_blocked_leads/2` private function in Foreman: takes contract metadata (lead_id, contract content) and `data`, checks `data.blocked_leads` for Leads whose dependency in `data.plan.dependencies` matches the publishing Lead, returns list of `{blocked_lead_id, lead_pid}` pairs to unblock.
- Update `{:lead_message, :contract, ...}` handler in Foreman: after promoting to site log, call `match_contract_to_blocked_leads/2`. For each match, send `{:foreman_contract, contract}` directly to the blocked Lead's PID, remove from `blocked_leads`, add to `started_leads`. Then include a summary in the next coalesced prompt to ForemanAgent: "Contract X published by Lead A, auto-forwarded to Lead B." (blocked: Add match_contract_to_blocked_leads/2)

### Code-speed orchestration: Lead message coalescing

- Add `lead_message_buffer` (list) and `lead_message_timer` (timer ref or nil) fields to Foreman initial state data. Add `job.lead_message_debounce` config key with default 2000ms.
- Update `{:lead_message, ...}` handler: only forward to ForemanAgent when in `:executing` state. For low-priority types (`:status`, `:artifact`, `:decision`, `:finding`), append to `lead_message_buffer` and start/reset `lead_message_timer` via `Process.send_after(self(), :flush_lead_messages, debounce)`. For high-priority types (`:contract`, `:blocker`, `:complete`, `:error`, `:critical_finding`), flush the buffer immediately plus the current message into a single consolidated prompt. (blocked: Add lead_message_buffer fields)
- Add `handle_event(:info, :flush_lead_messages, ...)` handler: build a consolidated prompt from `lead_message_buffer` contents, call `Deft.Agent.prompt/2` once, clear buffer and timer. (blocked: Add lead_message_buffer fields)

### Code-speed orchestration: crash decision timeout

- Add `job.lead_crash_decision_timeout` config key with default 60000ms.
- Update `do_handle_lead_crash`: after prompting ForemanAgent, return a `{:state_timeout, timeout, {:lead_crash_timeout, lead_id}}` action (or use `Process.send_after` if multiple crash timeouts need to coexist, since gen_statem only supports one state_timeout per state). Store pending crash lead_ids in a `pending_crash_decisions` map in state data. (blocked: Add lead_crash_decision_timeout config)
- Add `handle_event(:info, {:lead_crash_timeout, lead_id}, ...)` handler: if lead_id is still in `pending_crash_decisions` (ForemanAgent hasn't responded), auto-fail the deliverable — same logic as `fail_deliverable` handler. Log a warning. (blocked: Update do_handle_lead_crash)
- Update `fail_deliverable` and `spawn_lead` handlers: remove lead_id from `pending_crash_decisions` and cancel the pending timer. (blocked: Update do_handle_lead_crash)

### Cost ceiling gating

- Update `{:lead_message, ...}` handler: when `data.cost_ceiling_reached` is true, skip forwarding low-priority messages to ForemanAgent entirely. Still buffer them in `lead_message_buffer` for the catch-up prompt. (blocked: Add lead_message_buffer fields)
- Update `approve_continued_spending` handler: after resetting `cost_ceiling_reached`, flush `lead_message_buffer` as a single consolidated catch-up prompt to ForemanAgent. (blocked: Update lead_message handler for cost ceiling)
