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

## standards v0.2

### Phase 3: Replace primitives in specs and structs

- Update `Deft.Store.name` type from `{:cache, String.t(), String.t()}` to `{:cache, Session.session_id(), Job.lead_id()}` and `{:sitelog, String.t()}` to `{:sitelog, Job.job_id()}`

### Phase 4: Validate

- Run `mix dialyzer` with strict flags and fix any new violations introduced by the type changes. Ensure zero warnings, zero suppressed warnings.
