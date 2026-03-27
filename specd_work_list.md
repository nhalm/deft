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

## unit-testing v0.1

- Add Lead unit tests: deliverable decomposition, Runner spawning via Task.Supervisor, Runner crash/timeout handling, correct message types to Foreman (`:status`, `:decision`, `:contract`, `:complete`), `:foreman_steering` handling
- Add OM sync fallback unit test: verify forced observation/reflection when async falls behind
- Fix Foreman auto-approve test to verify actual state transition to `:executing` (currently only asserts config value)
- Add integration test scenario 2.2: Foreman Research → Decompose → Execute
- Add integration test scenario 2.3: Partial Unblocking Flow (blocked: unit-testing v0.1 scenario 2.2)
- Add integration test scenario 2.4: Resume from Saved State
- Add integration test scenario 2.5: Rate Limiter Integration
- Add integration test scenario 2.6: Observation Injection
