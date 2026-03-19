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

## evals v0.3

- Create missing fixture directories: `test/eval/fixtures/skills/`, `test/eval/fixtures/coding_conversations/`, `test/eval/fixtures/tool_results/`; skills suggestion test (suggestion_test.exs:57) crashes with MatchError because `{:ok, fixture} = load_fixture(fixture_path)` fails when fixtures don't exist
- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2 (blocked: fixtures/codebase_snapshots need synthetic repos)
- Create missing holdout infrastructure: `test/eval/fixtures/holdout/` directory, `@tag :holdout` tests, `make test.eval.holdout` target per spec section 1.4
- Create missing support modules: `test/eval/support/scoring.ex` (confidence interval reporting per spec section 1.5), `test/eval/support/judge_calibration.ex` (calibration set management per spec section 1.6)
