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

## orchestration v0.12

### Guard handle_lead_completion against absent lead_id

- Add a guard at the top of `handle_lead_completion`: extract lead_id from metadata, check `Map.has_key?(data.leads, lead_id)`. If the lead_id is not in `data.leads` (already removed by crash handler, abort, or fail_deliverable), log a warning and return `{:keep_state, data}` without mutating any tracking sets. This prevents a late `:complete` message from putting a lead_id into both `completed_leads` and `failed_leads`.

### Fix orphaned lead_id in started_leads on crash retry

- In `cancel_crash_decision_timer_for_deliverable` (called when `spawn_lead` retries a crashed deliverable): after cancelling the timer and removing from `pending_crash_decisions`, also remove the old crashed lead_id from `started_leads` and add it to `failed_leads`. The old lead_id is available in `pending_crash_decisions[lead_id].lead_id` or can be found by matching deliverable_id. This requires the crash decision entry to store the original lead_id.

### Simplify do_fail_job_on_foreman_agent_crash

- Rewrite `do_fail_job_on_foreman_agent_crash`: remove the manual `Enum.each` loops that stop Leads and clean worktrees (redundant with `cleanup/1`). The function should be: (1) demonitor all Leads with `:flush` by iterating `data.lead_monitors`, (2) demonitor ForemanAgent with `:flush`, (3) return `{:stop, {:foreman_agent_crashed, reason}, data}`. Let `terminate/3` → `cleanup(data)` handle all process stops, worktree cleanup, and site log shutdown.

### Simplify abort handler

- Rewrite the `:abort` cast handler: remove the explicit `cleanup(data)` call. Just return `{:stop, :normal, data}` and let `terminate/3` handle cleanup. Currently cleanup runs twice (once explicit, once from terminate).

### RateLimiter registered name for Leads

- Replace cached `rate_limiter_pid` in Foreman state with a registered name lookup: define a private `rate_limiter_name/1` helper that returns `{:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}}`. Replace `data.rate_limiter_pid` in `start_lead_process` (passed to Lead opts) with `rate_limiter_name(data)`. Remove `rate_limiter_pid` from the initial data map. RateLimiter registers under `{:rate_limiter, job_id}` in ProcessRegistry (confirmed in `lib/deft/job/rate_limiter.ex:324` and `lib/deft/job/supervisor.ex:54`).
