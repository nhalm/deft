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

## orchestration v0.14

- Replace cached ForemanAgent raw PID with via-tuple for all `Deft.Agent.prompt/2` calls. Keep the monitor ref separate. `setup_foreman_agent_monitoring/1` must store the via-tuple in `data.foreman_agent_pid`, not resolve to a raw PID.
- Rewrite `cleanup/1` ordering: (1) demonitor all (Leads with `:flush`, ForemanAgent, Store, RateLimiter), (2) terminate Lead supervisors via `DynamicSupervisor.terminate_child`, (3) clean worktrees, (4) stop Store. Wrap each step in `try/rescue` so filesystem errors don't skip remaining steps.
- Add ForemanAgent crash restart mechanism: on ForemanAgent `:DOWN`, start a new ForemanAgent with the session JSONL, re-establish the monitor, and send a catch-up prompt with current job state (active Leads, contracts, deliverable outcomes). Track restart count — fail job on restart failure OR second crash. (blocked: Replace cached ForemanAgent raw PID with via-tuple...)
- Add `foreman_agent_restarting` flag for degraded-mode buffering: when the flag is true during `:executing`, continue code-speed operations (contract forwarding, completion bookkeeping, crash timeouts) but buffer all messages that would go to ForemanAgent. On successful restart, flush buffer as a single consolidated prompt. Clear flag on restart success or job failure. (blocked: Add ForemanAgent crash restart mechanism...)
- Add DAG cycle validation in the `submit_plan` handler: validate all `:from`/`:to` IDs reference valid deliverable IDs, no self-loops, no cycles (topological sort). On invalid DAG, reject the plan and prompt ForemanAgent to fix it. Test: submit a plan with A→B→A cycle, verify rejection.
- Add file-overlap conflict detection in the Foreman: track modified files per Lead from `:artifact` messages in a `%{lead_id => MapSet.t()}` map. On each new `:artifact`, check `MapSet.intersection` against other active Leads. On overlap, pause both Leads and send the conflict to the ForemanAgent for resolution (steer/abort).
- Queue `{:foreman_steering, ...}` messages in Lead `:verifying` state instead of discarding. Add `queued_steering` list to Lead data. On transition to `:complete`, check queued steering — if present, send to LeadAgent and re-enter `:executing` if steering contradicts verification.
