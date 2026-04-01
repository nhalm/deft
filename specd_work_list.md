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

## orchestration v0.11

### Message coalescing: reclassify contract as low-priority

- Move `:contract` and `:contract_revision` from the high-priority list to the low-priority list in the Lead message handler. High-priority set becomes: `[:blocker, :complete, :error, :critical_finding]`. Low-priority set becomes: `[:status, :artifact, :decision, :finding, :contract, :contract_revision]`. Contract auto-unblocking already happened at code speed — the agent notification is informational.

### Process lifecycle: abort worktree leak

- Fix `do_abort_lead`: call `GitJob.cleanup_lead_worktree` with the Lead's worktree path BEFORE removing the Lead from `data.leads`. The worktree path is available in `data.leads[lead_id].worktree_path`. Currently the Lead is removed from the map first, so neither `do_abort_lead` nor `cleanup/1` ever cleans it.

### Process lifecycle: fail_deliverable cleanup for non-crashed Leads

- Fix `fail_deliverable` handler: after adding to `failed_leads` and removing from `started_leads`/`leads`, also call `cleanup_lead_monitor(data.lead_monitors, lead_id)` and remove from `lead_monitors`. If the Lead's worktree path is available (check `data.leads[lead_id]` before the map delete), call `GitJob.cleanup_lead_worktree`. Guard both operations — when called after a crash, `do_handle_lead_crash` already handled them. Read the worktree path from `data.leads[lead_id]` before deleting the entry.

### Process lifecycle: ForemanAgent crash cleanup ordering

- Fix `do_fail_job_on_foreman_agent_crash`: (1) move the `Enum.each` demonitor loop (currently after `cleanup(data)`) to BEFORE `cleanup(data)`. (2) Remove the redundant manual Lead stop loop (`Process.exit` on each lead) and the redundant worktree cleanup loop — `cleanup(data)` already does both. The function should be: demonitor all Leads with `:flush` → call `cleanup(data)` → return `{:stop, ...}`.

### Sibling process resilience: RateLimiter PID

- Replace cached `rate_limiter_pid` in Foreman state with a registered name lookup: define a private `rate_limiter_name/1` helper that returns `{:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}}`. Replace `data.rate_limiter_pid` in `start_lead_process` (passed to Lead opts) with `rate_limiter_name(data)`. Remove `rate_limiter_pid` from the initial data map. RateLimiter already registers under `{:rate_limiter, job_id}` in ProcessRegistry (confirmed in `lib/deft/job/rate_limiter.ex:324` and `lib/deft/job/supervisor.ex:54`).
