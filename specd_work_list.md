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

## tui v0.2

- Fix hardcoded `memory_threshold: 40_000` in Chat view (chat.ex:67): value is never read from OM config at mount time; status bar always shows `/40k` regardless of actual OM reflection threshold configuration

## orchestration v0.6

- Fix Lead `task_list` never populated (lead.ex:111): initialized as `[]` but no code parses LLM planning output to extract tasks; `continue_work` (lead.ex:1355-1376) always finds pending_tasks empty, skips `:executing` phase entirely, and transitions directly to `:verifying`; Lead never spawns implementation Runners
- Fix research task completion handler state guard (foreman.ex:896-902): handler only fires in `{:researching, :idle}`; if user sends a prompt during research, Foreman transitions to `{:researching, :calling}` and task `{ref, result}` messages are dropped by catch-all; job deadlocks since research phase never completes
- Fix verification runner completion handler state guard (foreman.ex:1183-1189): same pattern — handler only fires in `{:verifying, :idle}`; user prompt during verification drops the result; job never transitions to `:complete`
- Fix `inspect/1` on research findings in decomposition prompt (foreman.ex:2759): `inspect(finding)` wraps strings in double-quotes with escaped chars; LLM receives Elixir term syntax instead of raw text; use `finding` directly
- Fix Foreman `cancel_stream/1` no-op (foreman.ex:1585-1589): placeholder that logs and returns `:ok` without calling `provider.cancel_stream(data.stream_ref)`; streams continue running after abort/timeout, sending events to a transitioned state machine

## rate-limiter v0.1

- Fix queue bypass in `handle_call({:request, ...})` (rate_limiter.ex:393-406): when bucket capacity is available, new requests are granted immediately without checking if queued requests exist; violates FIFO ordering within same priority level; queued requests from before a backoff period wait up to an extra second while new same-priority requests are served inline

## git-strategy v0.2

- Fix merge-resolution retry off-by-one (foreman.ex:1103-1104): `max_retries = 3` with check `retry_count >= max_retries` allows 4 runner invocations (retry_count 0, 1, 2, 3) instead of 3; fix to `retry_count >= max_retries - 1` or start retry_count at 1
- Fix stash not restored when `complete_job` fails at worktree verification (git/job.ex:901-911): `with` chain short-circuits on `verify_no_worktrees` error after merge and branch deletion succeed; `pop_job_stash` is never called; user's pre-job changes are permanently stranded in stash

## observational-memory v0.3

- Fix `truncate_session_history_to_target` halt on first oversized line (state.ex:1682-1692): `Enum.reduce_while` with `{:halt, ...}` stops iteration entirely when a single line exceeds remaining budget; all older lines (which may individually fit) are dropped; should use `{:cont, ...}` to skip oversized lines and continue, keeping as many newest entries as possible
- Fix `current_task` from Observer silently discarded (state.ex:314-317, agent/context.ex:51-58): Observer extracts `current_task` (observer.ex:104) but it is never stored in State and `get_context/1` does not return it; `build_current_task_block/1` in context.ex always receives nil; spec section 3.5 requires current_task to be folded into `## Current State`

## skills v0.4

- Fix CLI `handle_user_input` missing catch-all for slash command I/O errors (cli.ex:1006-1027): `case` only handles `{:error, :not_found, _}` and `{:error, :no_definition, _}`; `SlashCommand.dispatch/1` can return `{:error, reason, name}` for POSIX errors (`:enoent`, `:eacces`); raises `CaseClauseError` at runtime; TUI (chat.ex:813) correctly handles this with a catch-all

## issues v0.5

- Fix `Issue.from_map/1` to handle missing required fields without raising (issue.ex:117-133): uses dot notation (`data.id`, `data.title`, etc.) which raises `KeyError` on incomplete JSONL; `load_issues/1` (issues.ex:472-481) only catches `{:error, reason}` returns, not exceptions; GenServer init crashes on structurally incomplete (but JSON-valid) lines instead of skipping with a warning

## sessions v0.4

- Implement `deft resume <session-id>` to start the TUI with restored conversation instead of displaying summary only: currently calls `execute_command({:resume_session, session_id}, flags)` which displays summary and returns `:ok` without starting agent loop or TUI (cli.ex:560-567); spec section 5.1 implies resume should actively resume the session, not just display it
