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

- Fix `DynamicSupervisor.terminate_child` calls to pass a PID instead of child spec ID tuple. `do_spawn_lead` stores `supervisor_child_id = {:lead, lead_id}` (the child spec `:id`, a tuple), but `DynamicSupervisor.terminate_child/2` requires a PID. This always returns `{:error, :not_found}`, silently leaving Lead subtrees (Lead, LeadAgent, ToolRunner, RunnerSupervisor) running after abort or cleanup. Fix: have `LeadSupervisor.start_lead` return the Lead.Supervisor PID from `start_child`, store it in `leads` map, and pass it to `terminate_child`.
