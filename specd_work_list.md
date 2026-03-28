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

### Tier 1: Largest files (10+ violations each)

- Refactor `lib/deft/tools/edit.ex` (16 violations): Group Myers diff params (old_lines, new_lines, n, m, max_d) into a ctx map — fixes 5 arity violations + nesting. Extract helpers from calculate_hunk_header, group_into_hunks, build_lcs_table, lcs_backtrack. Split execute/string_match_mode cyclomatic complexity via pattern-matched heads
- Refactor `lib/deft/cli.ex` (15 violations): Extract helpers from determine_command (CC 24, split into flag vs positional dispatch). Group start_agent optional params into opts map. Extract display helpers from display_issue_list, display_issue, create/update_interactive_issue, wait_for_job_completion. Flatten 4 nesting violations
- Refactor `lib/deft/agent.ex` (14 violations): Extract shared start_provider_stream helper (deduplicates 3 call sites). Split handle_event(:calling) case into pattern-matched function heads. Extract helpers from handle_tool_execution_complete (ABC 80), handle_idle_transition, save_tool_results, start_compaction_task. Flatten 4 nesting violations

### Tier 2: Medium files (5-8 violations each)

- Refactor `lib/deft/job/lead.ex` (8 violations): Extract helpers from handle_event(:info, runner_result), read_site_log_context, process_runner_result. Split evaluate_runner_output into pattern-matched heads. Flatten 4 nesting violations
- Refactor `lib/deft/om/state.ex` (7 violations): Group retry function args into context maps — fixes 4 arity violations (run_observer/reflector_with_retry and their loop variants). Extract helpers from handle_info observer completion, activate_buffered_chunks, truncate_session_history_to_target
- Refactor `lib/deft/job/rate_limiter.ex` (7 violations): Group try_request_or_enqueue params into map. Split track_cost into pipeline of pattern-matched helpers. Extract helpers from promote_starved_requests. Flatten 4 nesting violations
- Refactor `lib/deft/job/runner.ex` (6 violations): Create loop context struct/map bundling messages, tools, tool_context, job_id, provider, config, max_turns — fixes 4 arity violations (run, loop, do_loop_iteration, handle_assistant_message). Extract helpers from collect_loop (ABC 68) and execute_tools_inline
- Refactor `lib/deft/git/job.ex` (5 violations): Group handle_merge_failure params into map. Flatten 4 nesting violations in merge_lead_branch, pop_job_stash, complete_job by extracting inner branches
- Refactor `lib/deft/skills/registry.ex` (5 violations): Flatten 5 nesting violations by extracting inner case/if branches into named functions with pattern-matched heads
- Refactor `lib/deft/eval/judge_calibration.ex` (5 violations): Extract helpers from load_latest_result and calculate_metrics. Split calculate_metrics into count_classifications + compute_rates. Flatten 2 nesting violations

### Tier 3: Small files (2-4 violations each)

- Refactor `lib/deft/tools/bash.ex` (4 violations): Extract truncate_by_bytes/truncate_by_lines from truncate_output. Split execute into dispatch + pattern-matched handlers
- Refactor `lib/deft/om/reflector.ex` (4 violations): Group compress_with_retry/attempt_compression args into context map. Group collect_stream_text_loop accumulator into state map
- Refactor `lib/mix/tasks/eval.compare.ex` (4 violations): Extract helpers from compare and print_soft_floor_violations. Flatten 2 nesting violations
- Refactor `lib/deft/om/observer.ex` (3 violations): Extract helpers from run (ABC 53) to flatten nesting. Group collect_stream_text_loop accumulator into state map
- Refactor `lib/deft/om/observer/parse.ex` (3 violations): Extract helpers from parse_sections. Split extract_xml_blocks into pattern-matched per-tag functions
- Refactor `lib/deft_web/live/chat_live.ex` (3 violations): Extract helpers from mount. Split handle_scroll_key and handle_tmux_key into pattern-matched heads
- Refactor `lib/deft/eval/result_store.ex` (3 violations): Extract helpers from load and export. Flatten nesting in load
- Refactor `lib/deft/eval/baselines.ex` (3 violations): Extract decode/parse helpers from load. Change update from arity 6 to accept result map. Flatten nesting

### Tier 4: Single-violation files (1 each)

- Refactor `lib/deft/provider/anthropic.ex` (2 violations): Group stream_loop 10 params into state map. Split parse_event case into pattern-matched heads
- Refactor `lib/deft/tools/grep.ex` (2 violations): Flatten 2 nesting violations by extracting inner branches
- Refactor `lib/deft/session/entry.ex` (2 violations): Replace anonymous fn in serialize_content with named pattern-matched function. Reduce Observation.new arity
- Refactor `lib/deft/tools/issue_create.ex` (1 violation): Extract helpers from execute to reduce ABC size
- Refactor `lib/deft/tools/ls.ex` (1 violation): Extract helpers from summarize
- Refactor `lib/deft/session/store.ex` (1 violation): Flatten nesting
- Refactor `lib/deft/config.ex` (1 violation): Extract helpers from validate_and_build to reduce ABC size
- Refactor `lib/deft/agent/context.ex` (1 violation): Split get_om_context into pattern-matched heads
- Refactor `lib/deft/agent/tool_runner.ex` (1 violation): Flatten nesting
- Refactor `lib/deft/issues.ex` (1 violation): Group with_lock params into map
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
