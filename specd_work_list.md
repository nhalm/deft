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

## observational-memory v0.3

- Fix `calibrate_from_usage` to use `String.length` instead of `byte_size` (state.ex:1445): multi-byte characters (emoji priority markers 🔴🟡🟢 are 4 bytes each) inflate the calibration factor, causing threshold drift; `Tokens.estimate/2` was already fixed but the calibration path was missed

## orchestration v0.5

- Fix Foreman `call_llm/1` to pass read-only tools to the provider (foreman.ex:1518): `tools = []` is hardcoded but `execute_tool/2` at line 1463 defines `[Read, Grep, Find, Ls]`; the LLM never generates tool calls because it receives no tool definitions; Foreman cannot read the codebase during planning or decomposition
- Fix `RateLimiter.reconcile/4` to handle nil `actual_usage` (rate_limiter.ex:439): Runner's `collect_stream_events` initializes `usage = nil` (runner.ex:265); if no Usage events arrive, `RateLimiter.reconcile` is called with nil; `Map.get(nil, :input, ...)` raises `BadMapError`, crashing the RateLimiter GenServer for the entire job
- Fix merge-resolution retry counter to increment on each attempt (foreman.ex:2358): `handle_merge_retry_attempt` passes `retry_count` unchanged to `handle_lead_merge_with_retry`; should pass `retry_count + 1`; the retry cap of 3 is never enforced, allowing infinite merge-resolution loops
- Add `terminate/3` callback to Foreman for DETS cleanup (foreman.ex): in isolated startup (test, resume), the Foreman starts the site log Store directly without a supervisor; on Foreman exit, the Store is never stopped and the DETS file is not flushed; risk of DETS corruption on abnormal exit

## git-strategy v0.2

- Add stash pop on job failure/abort path (git/job.ex): `pop_job_stash/2` is called only in `complete_job/1` (success path); if a job fails or is aborted, the user's stashed changes are permanently stranded; add stash pop to the failure/abort cleanup
- Implement `abort_job/1` for failure cleanup (git/job.ex): spec Section 5 requires removing Lead worktrees, deleting the job branch (respecting `keep_failed_branches` config), and restoring the original branch; no abort/failure cleanup function exists; `keep_failed_branches` config is never read

## issues v0.5

- Fix double `get_job_cost` in abort path (cli.ex:2118,2345): `run_work_on_issue` calls `get_job_cost(job_id)` at line 2118 which stops the RateLimiter; then `handle_job_result({:error, :aborted}, ...)` calls `get_job_cost(job_id)` again at line 2345; the second call finds a dead process and returns 0.0; aborted jobs always report "$0.00" cost to the user
