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

- Fix foreman verification accuracy eval to call actual Foreman module instead of hardcoded rule: replace `make_foreman_decision/2` (line 264) with the real Foreman verification logic (LLM-based) and run statistically (20 iterations, 90% pass rate per spec)
- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2; create synthetic git repos in tmp dirs during test setup (use `System.cmd("git", ["init", ...])` in setup blocks); `test/support/git_mock.ex` already provides patterns for this

## evals v0.4

- Rewrite `cache_retrieval_test.exs` helpers to start a real agent with MockProvider (see pattern in `test/deft/agent_test.exs`): feed scripted LLM responses that should trigger `cache_read` tool calls; assert the agent actually invokes the tool rather than checking fixture string patterns
- Rewrite `agent_created_quality_test.exs` as a statistical eval: start an agent with MockProvider, have it process a fixture scenario and create issues; run 20 iterations with real LLM calls, assert 80% pass rate per spec section 1.5
- Fix `loop_safety_test.exs` stub: replace `run_loop_with_monitoring/2` with direct calls to CLI module functions (e.g., `Deft.CLI.execute_command/2`) or invoke the built escript via `System.cmd`; remove `:skip` tag once the real loop runs and produces meaningful data for safety assertions
