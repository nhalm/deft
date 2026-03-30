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

- Fix deliverable string/atom key mismatch: `submit_plan` stores JSON-decoded deliverables with string keys (`"id"`, `"description"`), but `LeadAgent.build_system_prompt` and `Lead.build_planning_context` access them with atom keys (`:name`, `:description`) → always nil. Normalize keys to atoms when storing the plan, or use string-key access downstream. Also fix `deliverable_already_started?` which uses `Map.get(lead.deliverable, :id)` on a string-keyed map.
- Pass RateLimiter PID to ForemanAgent through config when starting it in `Deft.Job.Supervisor`
- Pass RateLimiter PID to each LeadAgent through config when starting it
