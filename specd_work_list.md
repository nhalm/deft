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

## harness v0.4

- Fix RateLimiter reply pattern match in `call_provider_stream/5` (agent.ex:833): RateLimiter replies `{:ok, estimated_tokens}` but agent matches on bare `:ok` — all rate-limited LLM calls silently fail, falling through to the `{:error, reason}` arm
- Fix `_estimated_tokens` not persisted to agent state for reconciliation (agent.ex:835,991): `config_with_estimate` is a local variable passed to `provider.stream` but never stored in `data.config` — `handle_usage` always reads `_estimated_tokens` as `0`, making reconciliation a no-op

## orchestration v0.7

- Fix Registry session ID mismatch between Foreman and ForemanAgent (foreman.ex:171, supervisor.ex:60,147): Foreman subscribes to `{:session, job_id}` but ForemanAgent broadcasts under `{:session, "#{job_id}-foreman"}` — the asking phase relay loop receives zero events, questions are never forwarded to the user
- Fix research result collection Task ownership violation (foreman.ex:216-219,1065-1073): research tasks are owned by the Foreman process but `collect_research_results` calls `Task.yield` from a separate collector task — `Task.yield` raises or hangs because caller is not the task owner
- Fix Lead crash handler treating crashed Leads as successfully completed (foreman.ex:1017-1020): when a crashed Lead is the last in `started_leads`, Foreman transitions to `:verifying` with missing deliverables — should not count a crash as completion
