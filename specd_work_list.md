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

- Replace `run_deft_work/3` stub in `single_task_test.exs` (line 347) with real CLI invocation via `System.cmd`
- Replace `run_deft_with_strategy/4` and `run_synthetic_task/3` stubs in `multi_agent_test.exs` (lines 232, 295) with real CLI invocation
- Replace `run_deft_work/3` stub in `verification_circuit_breaker_test.exs` (line 320) with real CLI invocation
- Implement scenario-specific repo setup in `single_task_test.exs`: `create_basic_project_structure/2` (line 284) ignores `_scenario` — each of the 8 benchmark tasks needs a distinct repo with the prerequisite code for that scenario
- Create `test/eval/support/scoring.ex` implementing confidence interval reporting per spec section 1.5 report format
- Create observer eval tests: `test/eval/observer/{extraction,priority,section_routing,anti_hallucination,dedup}_test.exs` per spec section 1.2
- Create reflector eval tests: `test/eval/reflector/{compression,preservation}_test.exs` per spec section 1.2
- Create actor eval tests: `test/eval/actor/{observation_usage,continuation,tool_selection}_test.exs` per spec section 1.2
- Create foreman eval tests: `test/eval/foreman/{decomposition,dependency,contract,constraint_propagation}_test.exs` per spec section 1.2
- Create lead eval tests: `test/eval/lead/{task_planning,steering}_test.exs` per spec section 1.2
- Create `test/eval/spilling/threshold_calibration_test.exs` per spec section 1.2
- Create skills eval tests: `test/eval/skills/{suggestion,invocation_fidelity}_test.exs` per spec section 1.2
- Create `test/eval/issues/elicitation_quality_test.exs` per spec section 1.2
- Create `test/eval/fixtures/` directory structure with synthetic fixture JSON files per spec section 1.3

