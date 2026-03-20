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

## orchestration v0.6

- Replace `determine_research_tasks/1` stub with LLM-based research planning: currently (foreman.ex:2658-2675) always returns two hardcoded generic tasks ("Analyze codebase structure" and "Identify existing patterns") regardless of prompt; spec section 3.1 requires the Foreman to analyze the request during `:planning` and determine what research is needed; the planning phase LLM call response is currently discarded

## git-strategy v0.2

- Wire `job_test_command` and `job_squash_on_complete` from `Config` through CLI `agent_config` map: `start_job_and_wait` (cli.ex:2240-2261) omits both fields; Foreman falls back to hardcoded defaults via `Map.get(data.config, :job_test_command, "mix test")` and `Map.get(data.config, :job_squash_on_complete, true)`, making user `.deft/config.yaml` settings for these fields no-ops
- Fix misleading error message in Foreman when `verify_no_worktrees` fails after successful merge: `complete_job` returns `{:error, {:worktrees_remain, n}}` after merge succeeds and job branch is deleted; Foreman (foreman.ex:1236-1257) shows "failed to merge changes" and tells user to "manually merge the job branch" which no longer exists; should report orphan worktrees as a warning, not a merge failure

## tools v0.2

- Fix `find` tool: add `--glob` flag to `fd` invocation in `execute_fd/2` (line 79-88); without it, `fd` interprets the pattern as regex instead of glob — `*.ex` matches "zero or more `e`s followed by `x`" instead of all `.ex` files, producing wrong/empty results silently

## rate-limiter v0.2

- Wire `initial_concurrency` config: add `job_initial_concurrency` field to `Deft.Config`, pass it from `Job.Supervisor` to `RateLimiter.start_link/1` opts; currently always defaults to 2 regardless of user configuration (spec section 7 defines `job.initial_concurrency` as configurable)

## evals v0.4 (new)

- Fix PII safety eval crash-fallback in tier1-evals.yml: hallucination check (lines 94-97) sets `SAFETY_FAILURE=1` when tests exit non-zero without "Pass rate:" output; PII check (lines 104-129) has no equivalent fallback — a crashing PII test silently passes the safety gate

## evals v0.4

- Rewrite `cache_retrieval_test.exs` helper functions (lines 171-208) to actually test agent behavior: `agent_retrieves_cache?/3`, `agent_retrieves_cache_with_filter?/4`, and `agent_retrieves_cache_with_grep_filter?/4` are tautologies that check fixture string patterns (never start an agent); always return true giving 100% pass rate regardless of actual agent behavior (blocked: agent loop testability)
- Rewrite `agent_created_quality_test.exs` to be a statistical eval: currently constructs Issue structs directly from fixture data via `build_issue_from_fixture/1` and asserts on fixture fields — never calls an LLM or agent; spec section 1.5 requires 80% over 20 iterations as a statistical eval that detects model quality regressions (blocked: agent loop testability)
- Fix `loop_safety_test.exs` stub: `run_loop_with_monitoring/2` (line 207) returns hardcoded `%{success: true, issues_processed: 0, ...}` and discards CLI args; when `:skip` tag is removed, all safety assertions (`assert_no_false_closes`, `assert_no_cost_anomalies`, etc.) pass trivially on empty data; must invoke actual CLI or agent loop (blocked: CLI invocation mechanism in test env)

## evals v0.3

- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2 (blocked: fixtures/codebase_snapshots need synthetic repos)
- Implement `call_llm_judge/2` in `test/eval/support/eval_helpers.ex`: currently returns `{:ok, "Pending implementation"}` unconditionally (line 39); all evals that depend on LLM-as-judge (spilling summary quality, cache retrieval, foreman decomposition) pass vacuously with 100% regardless of actual model quality (blocked: provider availability in test env)
- Fix foreman verification accuracy eval to call actual Foreman module instead of hardcoded rule: `verification_accuracy_test.exs` defines its own `make_foreman_decision/2` (line 264) that uses a pure boolean formula; must invoke the real Foreman verification logic (LLM-based) and run statistically (20 iterations, 90% pass rate per spec) (blocked: call_llm_judge implementation)
- Fix `summary_quality_test.exs` to use actual LLM judge: `judge_summary_quality/3` (line 264) uses heuristic checks (size reduction, regex matches) that deterministically pass on well-formed summaries; spec section 1.6 requires LLM-as-judge validated to >85% precision and recall (blocked: call_llm_judge implementation)

