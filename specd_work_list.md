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

## evals v0.4

- Restore all eval test files (5th regression): `test/eval/` contains only `support/scoring.ex`; all 26+ component tests, fixtures, and support modules are missing again; restore from git history; previous 4 restorations all regressed — root cause of recurring deletion must be identified and prevented
- Fix `scoring.ex` compile path: `test/eval/support/scoring.ex` is not under `elixirc_paths(:test)` (`["lib", "test/support"]`); `Deft.Eval.Scoring` will not be compiled; either move to `test/support/eval/scoring.ex` or add `"test/eval/support"` to `elixirc_paths`
- Fix `determine_status/4` FAIL logic: when no `:baseline` opt is passed (the default), rate below `soft_floor` returns `:warn` instead of `:fail`; line 138 checks `baseline && rate < baseline - 0.10` which is falsy when baseline is nil; should be `rate < soft_floor -> :fail` per spec section 1.5 and the function's own docstring
- Rewrite `cache_retrieval_test.exs` helper functions (lines 171-208) to actually test agent behavior: `agent_retrieves_cache?/3`, `agent_retrieves_cache_with_filter?/4`, and `agent_retrieves_cache_with_grep_filter?/4` are tautologies that check fixture string patterns (never start an agent); always return true giving 100% pass rate regardless of actual agent behavior (blocked: agent loop testability)

## evals v0.3

- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2 (blocked: fixtures/codebase_snapshots need synthetic repos)
- Implement `call_llm_judge/2` in `test/eval/support/eval_helpers.ex`: currently returns `{:ok, "Pending implementation"}` unconditionally (line 39); all evals that depend on LLM-as-judge (spilling summary quality, cache retrieval, foreman decomposition) pass vacuously with 100% regardless of actual model quality (blocked: provider availability in test env)
- Fix foreman verification accuracy eval to call actual Foreman module instead of hardcoded rule: `verification_accuracy_test.exs` defines its own `make_foreman_decision/2` (line 264) that uses a pure boolean formula; must invoke the real Foreman verification logic (LLM-based) and run statistically (20 iterations, 90% pass rate per spec) (blocked: call_llm_judge implementation)
