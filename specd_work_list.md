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

- Rewrite `cache_retrieval_test.exs` helper functions (lines 171-208) to actually test agent behavior: `agent_retrieves_cache?/3`, `agent_retrieves_cache_with_filter?/4`, and `agent_retrieves_cache_with_grep_filter?/4` are tautologies that check fixture string patterns (never start an agent); always return true giving 100% pass rate regardless of actual agent behavior (blocked: agent loop testability)
- Rewrite `agent_created_quality_test.exs` to be a statistical eval: currently constructs Issue structs directly from fixture data via `build_issue_from_fixture/1` and asserts on fixture fields — never calls an LLM or agent; spec section 1.5 requires 80% over 20 iterations as a statistical eval that detects model quality regressions (blocked: agent loop testability)
- Fix `loop_safety_test.exs` stub: `run_loop_with_monitoring/2` (line 207) returns hardcoded `%{success: true, issues_processed: 0, ...}` and discards CLI args; when `:skip` tag is removed, all safety assertions (`assert_no_false_closes`, `assert_no_cost_anomalies`, etc.) pass trivially on empty data; must invoke actual CLI or agent loop (blocked: CLI invocation mechanism in test env)

## evals v0.3

- Create missing e2e test files: `test/eval/e2e/single_task_test.exs`, `test/eval/e2e/multi_agent_test.exs`, `test/eval/e2e/verification_circuit_breaker_test.exs` per spec section 1.2 (blocked: fixtures/codebase_snapshots need synthetic repos)
- Implement `call_llm_judge/2` in `test/eval/support/eval_helpers.ex`: currently returns `{:ok, "Pending implementation"}` unconditionally (line 39); all evals that depend on LLM-as-judge (spilling summary quality, cache retrieval, foreman decomposition) pass vacuously with 100% regardless of actual model quality (blocked: provider availability in test env)
- Fix foreman verification accuracy eval to call actual Foreman module instead of hardcoded rule: `verification_accuracy_test.exs` defines its own `make_foreman_decision/2` (line 264) that uses a pure boolean formula; must invoke the real Foreman verification logic (LLM-based) and run statistically (20 iterations, 90% pass rate per spec) (blocked: call_llm_judge implementation)
- Fix `summary_quality_test.exs` to use actual LLM judge: `judge_summary_quality/3` (line 264) uses heuristic checks (size reduction, regex matches) that deterministically pass on well-formed summaries; spec section 1.6 requires LLM-as-judge validated to >85% precision and recall (blocked: call_llm_judge implementation)

## observational-memory v0.3

- Fix `current_task` from Observer silently discarded (state.ex:314-317, agent/context.ex:51-58): Observer extracts `current_task` (observer.ex:104) but it is never stored in State and `get_context/1` does not return it; `build_current_task_block/1` in context.ex always receives nil; spec section 3.5 requires current_task to be folded into `## Current State`

## skills v0.4

- Fix CLI `handle_user_input` missing catch-all for slash command I/O errors (cli.ex:1006-1027): `case` only handles `{:error, :not_found, _}` and `{:error, :no_definition, _}`; `SlashCommand.dispatch/1` can return `{:error, reason, name}` for POSIX errors (`:enoent`, `:eacces`); raises `CaseClauseError` at runtime; TUI (chat.ex:813) correctly handles this with a catch-all

## issues v0.5

- Fix `Issue.from_map/1` to handle missing required fields without raising (issue.ex:117-133): uses dot notation (`data.id`, `data.title`, etc.) which raises `KeyError` on incomplete JSONL; `load_issues/1` (issues.ex:472-481) only catches `{:error, reason}` returns, not exceptions; GenServer init crashes on structurally incomplete (but JSON-valid) lines instead of skipping with a warning

## sessions v0.4

- Implement `deft resume <session-id>` to start the TUI with restored conversation instead of displaying summary only: currently calls `execute_command({:resume_session, session_id}, flags)` which displays summary and returns `:ok` without starting agent loop or TUI (cli.ex:560-567); spec section 5.1 implies resume should actively resume the session, not just display it
