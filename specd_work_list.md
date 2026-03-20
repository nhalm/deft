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

## tools v0.2

- Fix `calculate_hunk_header` multi-hunk line numbers (edit.ex:379): line counter initializes at `{1, 1}` for every hunk; `group_into_hunks` doesn't pass the starting file position; all hunks after the first get wrong `@@` headers (e.g., `@@ -1,... @@` instead of `@@ -40,... @@`); must propagate each hunk's starting index from `group_into_hunks` to `generate_hunk_with_header`

## git-strategy v0.2

- Fix `abort_job` to skip branch checkout when `original_branch` is not set (foreman.ex:667): abort handler fires in any state (line 650); `original_branch` is only stored after `create_job_branch` succeeds (line 397); early abort (during planning/decomposing) defaults to `"main"` and incorrectly checks out main regardless of user's actual branch; should either store original branch at Foreman init time or skip checkout when no job branch was created
- Move stash prompt from Foreman to CLI/TUI layer before Foreman.start_link: Foreman hardcodes `auto_approve: true` when calling `GitJob.create_job_branch` (foreman.ex:393), making the stash-prompt path unreachable; dirty working trees always fail with `{:error, :dirty_working_tree}`; spec section 1 requires "warn the user and ask to stash" but GenServers cannot do interactive I/O; must move the stash check and prompt to the CLI/TUI layer before starting the Foreman so the working tree is clean before `create_job_branch` runs

## evals v0.4

- Rewrite `cache_retrieval_test.exs` helper functions (lines 171-208) to actually test agent behavior: `agent_retrieves_cache?/3`, `agent_retrieves_cache_with_filter?/4`, and `agent_retrieves_cache_with_grep_filter?/4` are tautologies that check fixture string patterns (never start an agent); always return true giving 100% pass rate regardless of actual agent behavior (blocked: agent loop testability)
- Rewrite `agent_created_quality_test.exs` to be a statistical eval: currently constructs Issue structs directly from fixture data via `build_issue_from_fixture/1` and asserts on fixture fields — never calls an LLM or agent; spec section 1.5 requires 80% over 20 iterations as a statistical eval that detects model quality regressions (blocked: agent loop testability)
- Fix `loop_safety_test.exs` stub: `run_loop_with_monitoring/2` (line 207) returns hardcoded `%{success: true, issues_processed: 0, ...}` and discards CLI args; when `:skip` tag is removed, all safety assertions (`assert_no_false_closes`, `assert_no_cost_anomalies`, etc.) pass trivially on empty data; must invoke actual CLI or agent loop (blocked: CLI invocation mechanism in test env)
- Fix `test.eval.check-structure` Makefile threshold (line 45): `-ge 0` is always true regardless of how many test files exist; should be `-ge 1` (or a meaningful minimum) so CI catches the empty test/eval/ directory

## rate-limiter v0.2

- Pass `max_leads` config to RateLimiter in `Job.Supervisor.init/1` (supervisor.ex:83): RateLimiter receives only `job_id`, `foreman_pid`, `cost_ceiling`; its `max_concurrency` defaults to 10 while Foreman's `job_max_leads` defaults to 5; RateLimiter must receive `max_leads` from config so its adaptive concurrency ceiling matches the Foreman's actual Lead cap

## evals v0.3

- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2 (blocked: fixtures/codebase_snapshots need synthetic repos)
- Implement `call_llm_judge/2` in `test/eval/support/eval_helpers.ex`: currently returns `{:ok, "Pending implementation"}` unconditionally (line 39); all evals that depend on LLM-as-judge (spilling summary quality, cache retrieval, foreman decomposition) pass vacuously with 100% regardless of actual model quality (blocked: provider availability in test env)
- Fix foreman verification accuracy eval to call actual Foreman module instead of hardcoded rule: `verification_accuracy_test.exs` defines its own `make_foreman_decision/2` (line 264) that uses a pure boolean formula; must invoke the real Foreman verification logic (LLM-based) and run statistically (20 iterations, 90% pass rate per spec) (blocked: call_llm_judge implementation)
- Fix `summary_quality_test.exs` to use actual LLM judge: `judge_summary_quality/3` (line 264) uses heuristic checks (size reduction, regex matches) that deterministically pass on well-formed summaries; spec section 1.6 requires LLM-as-judge validated to >85% precision and recall (blocked: call_llm_judge implementation)

