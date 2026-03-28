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

## standards v0.2 — Credo violation fixes

### Infrastructure (after all violations fixed)

- Update `Makefile`: add `dialyzer` target to `check`
- Update `lefthook.yml`: add `dialyzer` to pre-commit (blocked: Update Makefile)
- Run `mix dialyzer`, fix all warnings until clean — add missing `@spec` annotations as needed (blocked: Update lefthook.yml)

## unit-testing v0.1

- Add integration test scenario 2.4: Resume from Saved State
- Add integration test scenario 2.5: Rate Limiter Integration
- Add integration test scenario 2.6: Observation Injection
