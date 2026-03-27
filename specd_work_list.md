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

## unit-testing v0.1

- Add Foreman unit test: cost ceiling enforcement — simulate `{:rate_limiter, :cost, amount}` message exceeding ceiling, verify Foreman pauses new Lead spawning in `foreman_test.exs`
- Add Foreman unit test: single-agent fallback — verify simple task (1-2 files) skips orchestration and executes directly in `foreman_test.exs`
- Add integration test: single-agent turn loop using ScriptedProvider — assistant responds with tool call, tool executes, assistant responds with text. Verify full state machine cycle in `test/integration/agent_turn_test.exs`
- Add integration test: Foreman research → decompose → execute using ScriptedProvider — script planning response, research findings, decomposition with deliverables/DAG. Verify phase transitions and plan storage in `test/integration/foreman_phases_test.exs`
- Add integration test: partial unblocking flow using ScriptedProvider — Lead A publishes contract, Lead B starts with contract context before Lead A completes. Verify in `test/integration/partial_unblock_test.exs` (blocked: Add integration test Foreman research → decompose → execute)
- Add integration test: resume from persisted state — write mid-job state (site log + plan.json), start new Foreman with `resume: true`, verify only incomplete deliverables get fresh Leads in `test/integration/resume_test.exs`

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
