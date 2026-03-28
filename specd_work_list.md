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

### Tier 3: Small files (2-4 violations each)

- Refactor `lib/deft/eval/baselines.ex` (3 violations): Extract decode/parse helpers from load. Change update from arity 6 to accept result map. Flatten nesting

### Tier 4: Single-violation files (1 each)

- Refactor `lib/deft/provider/anthropic.ex` (2 violations): Group stream_loop 10 params into state map. Split parse_event case into pattern-matched heads
- Refactor `lib/deft/tools/grep.ex` (2 violations): Flatten 2 nesting violations by extracting inner branches
- Refactor `lib/deft/session/entry.ex` (2 violations): Replace anonymous fn in serialize_content with named pattern-matched function. Reduce Observation.new arity
- Refactor `lib/deft/eval/fixture_validator.ex` (1 violation): Flatten nesting
- Refactor `test/support/scripted_provider.ex` (1 violation): Flatten nesting
- Refactor `test/deft/git/job_test.exs` (1 violation): Split mock cmd into pattern-matched heads
- Refactor `test/support/eval/lead_helpers.ex` (1 violation): Split extract_json into pattern-matched heads

### Infrastructure (after all violations fixed)

- Update `Makefile`: add `dialyzer` target to `check` (blocked: all Tier 1-4 items)
- Update `lefthook.yml`: add `dialyzer` to pre-commit (blocked: Update Makefile)
- Run `mix dialyzer`, fix all warnings until clean — add missing `@spec` annotations as needed (blocked: Update lefthook.yml)

## unit-testing v0.1

- Add integration test scenario 2.2: Foreman Research → Decompose → Execute
- Add integration test scenario 2.3: Partial Unblocking Flow (blocked: unit-testing v0.1 scenario 2.2)
- Add integration test scenario 2.4: Resume from Saved State
- Add integration test scenario 2.5: Rate Limiter Integration
- Add integration test scenario 2.6: Observation Injection
