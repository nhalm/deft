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

## skills v0.4

- Fix CLI skill injection to use system-level instructions (cli.ex:987-995): CLI returns skill definition via `{:ok, text}` which goes to `Deft.Agent.prompt/2` (user message); spec section 2.4 requires skills to be injected as system instructions; TUI correctly uses `{:inject_skill, full_text}` — CLI must match; the TODO comment at line 989 acknowledges this bug

## harness v0.2

- Fix abort in `:executing_tools` to terminate inner per-tool tasks (agent.ex:1079-1088): `cancel_state_operations` only kills the outer wrapper task via `Task.Supervisor.terminate_child`; inner tasks spawned by `ToolRunner.execute_batch` under the same supervisor continue running until timeout (up to 120s); must either track inner tasks or terminate all children of the supervisor
- Fix `om_enabled` default in `maybe_compact_messages` (agent.ex:1540): defaults to `false` but all other call sites (agent.ex:691, context.ex:90, config.ex:321) default to `true`; with a bare-map config, compaction runs alongside OM, violating the mutual-exclusion invariant; change default to `true`
- Fix turn counter off-by-one (agent.ex:1430): the initial prompt-triggered LLM call is never counted in `turn_count` (only incremented in `continue_after_tools`); with `max_turns: 25`, 26 LLM calls happen; either increment `turn_count` on the initial call or start `turn_count` at 1 when entering `:calling`

## observational-memory v0.3

- Fix `Tokens.estimate/2` to use `String.length` instead of `byte_size` (tokens.ex:26): `byte_size` returns bytes not characters; multi-byte UTF-8 characters (emoji priority markers 🔴🟡🟢 are 4 bytes each) inflate token estimates by up to 4x; causes observation/reflection cycles to trigger prematurely
- Fix `keep_tail/3` to skip oversized messages instead of halting (context.ex:112-124): `reduce_while` halts on the first message that exceeds remaining budget; if the most recent message is large (e.g., big tool result), zero messages are kept; should use `{:cont, ...}` to skip and continue, preserving conversational continuity per spec
- Wire OM threshold config fields from spec section 8 through `Deft.Config`: `om.message_token_threshold`, `om.observation_token_threshold`, `om.buffer_interval`, `om.buffer_tail_retention`, `om.hard_threshold_multiplier`, `om.previous_observer_tokens` are all hardcoded as module constants in state.ex; cannot be tuned without code changes

## git-strategy v0.2

- Add git stash pop after job completion (git/job.ex): if the user's uncommitted changes were stashed before job creation (line 133-134), the stash is never popped after `complete_job`; user's working state is not restored; add `git stash pop` on the success path of `complete_job` and warn on failure
- Add retry cap for merge-resolution Runner (foreman.ex:1000-1012): when a merge-resolution Runner succeeds but `handle_lead_merge` still returns `:conflict`, another merge-resolution Runner is spawned with no cap; infinite loop possible; add a max retry count (e.g., 3) and fail the merge after exhausting retries

## evals v0.3

- Implement safety eval hard-fail gate in CI workflow (.github/workflows/tier1-evals.yml:55-67): the step currently has a TODO and exits 0 unconditionally; must parse test output for safety eval pass rates and hard fail the build if any safety category (hallucination, PII) drops below 90% per spec section 3.2

## filesystem v0.4

- Change Store async load from `Task.async` to `Task.async_nolink` (store.ex:177): `Task.async` creates a link; if the load task crashes (e.g., DETS iteration error), the linked exit kills the Store GenServer before the `{:DOWN, ...}` handler at line 252 can fire; `Task.async_nolink` preserves the monitor-based error handling that the spec requires (graceful degradation to `:miss` on load failure)
- Fix `resolve_real_path` to use `File.realpath/1` instead of `:file.read_link_all/1` (project.ex:126-133): `:file.read_link_all/1` only resolves the final path component; if an intermediate directory is a symlink (e.g., `/home/nick` → `/Users/nick`), the symlink is not resolved; two paths to the same repo produce different project directories, siloing sessions and cache

## issues v0.5

- Add explicit `handle_job_result({:error, :aborted}, ...)` clause in CLI (cli.ex:2304-2319): non-SIGINT Foreman aborts (`:shutdown` exit) produce `{:error, :aborted}` from `wait_for_job_completion`; this falls through to the generic `{:error, reason}` handler which calls `exit({:shutdown, 1})`; the work loop's graceful abort branch (print "Job aborted", report cost, return `:ok`) is unreachable for non-SIGINT aborts