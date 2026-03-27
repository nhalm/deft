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

## standards v0.2

- Create custom Credo check `Deft.Check.Refactor.FunctionBodyLength` in `lib/deft/checks/function_body_length.ex` — uses `Credo.Code.prewalk` to count lines in `def`/`defp` bodies, flags functions exceeding 25 lines. Register in `.credo.exs`
- Create custom Credo check `Deft.Check.Refactor.ModuleLength` in `lib/deft/checks/module_length.ex` — counts non-blank, non-comment lines in `defmodule` body, flags modules exceeding 400 lines. Register in `.credo.exs`
- Fix all new Credo violations introduced by tightened thresholds — run `mix credo --strict`, fix each violation by extracting functions, reducing arity, or simplifying control flow. Do NOT suppress with inline `credo:disable` comments (blocked: Create custom Credo check FunctionBodyLength, Create custom Credo check ModuleLength)
- Update `Makefile`: change `check` target from `compile format.check lint test.eval.check-structure test` to `compile format.check lint dialyzer test.eval.check-structure test` (blocked: Fix all new Credo violations)
- Update `lefthook.yml`: add `dialyzer` command to `pre-commit` section with `run: mix dialyzer` (blocked: Fix all new Credo violations)
- Run `mix dialyzer` to build initial PLT, then fix all Dialyzer warnings until `mix dialyzer` exits clean. Add missing `@spec` annotations on public functions as needed. This will find many errors — work through them methodically, one module at a time (blocked: Update Makefile, Update lefthook.yml)

## unit-testing v0.1

- Add integration test: Foreman research → decompose → execute using ScriptedProvider — script planning response, research findings, decomposition with deliverables/DAG. Verify phase transitions and plan storage in `test/integration/foreman_phases_test.exs` (blocked: Foreman KeyError bug with :estimated_tokens needs fix)
- Add integration test: partial unblocking flow using ScriptedProvider — Lead A publishes contract, Lead B starts with contract context before Lead A completes. Verify in `test/integration/partial_unblock_test.exs` (blocked: Add integration test Foreman research → decompose → execute)
- Add integration test: resume from persisted state — write mid-job state (site log + plan.json), start new Foreman with `resume: true`, verify only incomplete deliverables get fresh Leads in `test/integration/resume_test.exs`

## web-ui v0.4

- Implement force-abort for double Ctrl+c in chat_live.ex: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
