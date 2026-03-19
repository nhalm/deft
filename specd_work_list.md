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

## orchestration v0.3

- Implement `process_provider_event/2` in Foreman to accumulate streaming text and tool calls into `data.current_message` (foreman.ex:1038-1042): currently a no-op that discards all LLM response events; planning, decomposition, and steering produce no output
- Implement `finalize_streaming/1` in Foreman to build a complete assistant message from accumulated stream data (foreman.ex:1049-1056): currently just calls `save_unsaved_messages/1` which has nothing to save since events were never accumulated
- Implement `add_tool_results/2` in Foreman to inject tool results into the message list (foreman.ex:1058-1062): currently a no-op; Foreman agent loop cannot complete tool execution cycles
- Implement `process_provider_event/2` in Lead to accumulate streaming text and tool calls (lead.ex:723-726): same no-op placeholder as Foreman; Lead cannot process LLM responses for task decomposition or steering
- Implement `finalize_streaming/1` in Lead to build complete assistant message from stream (lead.ex:733-740): same placeholder as Foreman
- Implement `add_tool_results/2` in Lead to inject tool results into messages (lead.ex:742-746): same placeholder as Foreman
- Add orchestration config keys to `Deft.Config`: `job_max_leads`, `job_max_runners_per_lead`, `job_research_timeout`, `job_runner_timeout`, `job_foreman_model`, `job_lead_model`, `job_runner_model`, `job_research_runner_model`, `job_max_duration` per spec section 8; parse from `job.*` in config YAML; wire through CLI `agent_config` map so Foreman/Lead can read them

## git-strategy v0.1

- Fix `merge_lead_branch/1` `@spec` to match actual return type (git/job.ex:315-316): spec says `{:ok, :conflict, [String.t()]}` but function returns `{:ok, :conflict, [String.t()], String.t()}` (4-tuple including temp_dir path); any caller written to the published spec crashes on conflict

## issues v0.3

- Fix `run_work_on_issue` to start Foreman through `Job.Supervisor.start_link/1` instead of calling `Foreman.start_link/1` directly (cli.ex:2080-2086): direct call omits required `:runner_supervisor` argument; `Keyword.fetch!` at foreman.ex:66 raises `KeyError`; `deft work` is completely non-functional

