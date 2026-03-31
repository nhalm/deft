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

### Sibling process resilience

- Replace cached `rate_limiter_pid` in Foreman state with a registered name lookup function: define a private `rate_limiter_pid/1` helper that does `GenServer.whereis({:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, data.session_id}}})`. Replace all `data.rate_limiter_pid` reads with calls to this helper. Remove `rate_limiter_pid` from the initial data map. (blocked: Verify RateLimiter registers under this name in ProcessRegistry)

### Code-speed orchestration: contract auto-unblocking

### Code-speed orchestration: crash decision timeout

- Add `handle_event(:info, {:lead_crash_timeout, lead_id}, ...)` handler: if lead_id is still in `pending_crash_decisions` (ForemanAgent hasn't responded), auto-fail the deliverable — same logic as `fail_deliverable` handler. Log a warning.
- Update `fail_deliverable` and `spawn_lead` handlers: remove lead_id from `pending_crash_decisions` and cancel the pending timer.

### Cost ceiling gating

- Update `{:lead_message, ...}` handler: when `data.cost_ceiling_reached` is true, skip forwarding low-priority messages to ForemanAgent entirely. Still buffer them in `lead_message_buffer` for the catch-up prompt.
- Update `approve_continued_spending` handler: after resetting `cost_ceiling_reached`, flush `lead_message_buffer` as a single consolidated catch-up prompt to ForemanAgent. (blocked: Update lead_message handler for cost ceiling)
