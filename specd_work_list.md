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

### Process lifecycle: ForemanAgent crash cleanup ordering

- Fix `do_fail_job_on_foreman_agent_crash`: (1) move the `Enum.each` demonitor loop (currently after `cleanup(data)`) to BEFORE `cleanup(data)`. (2) Remove the redundant manual Lead stop loop (`Process.exit` on each lead) and the redundant worktree cleanup loop — `cleanup(data)` already does both. The function should be: demonitor all Leads with `:flush` → call `cleanup(data)` → return `{:stop, ...}`.

### Sibling process resilience: RateLimiter PID

- Replace cached `rate_limiter_pid` in Foreman state with a registered name lookup: define a private `rate_limiter_name/1` helper that returns `{:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}}`. Replace `data.rate_limiter_pid` in `start_lead_process` (passed to Lead opts) with `rate_limiter_name(data)`. Remove `rate_limiter_pid` from the initial data map. RateLimiter already registers under `{:rate_limiter, job_id}` in ProcessRegistry (confirmed in `lib/deft/job/rate_limiter.ex:324` and `lib/deft/job/supervisor.ex:54`).
