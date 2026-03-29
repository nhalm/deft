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

- Remove `@dialyzer {:nowarn_function, defaults: 0}` from `lib/deft/config.ex:172` and fix the underlying Dialyzer violation
- Remove `@dialyzer {:nowarn_function, build_runner_context: 2}` and `{:nowarn_function, determine_runner_type: 1}` from `lib/deft/job/lead.ex` and fix the underlying Dialyzer violations
- Remove `@dialyzer {:nowarn_function, analyze: 4}` from `lib/deft/eval/regression_detection.ex:178` and fix the underlying Dialyzer violation
- Remove `@dialyzer {:nowarn_function, export: 1}` from `lib/deft/eval/result_store.ex:197` and fix the underlying Dialyzer violation
- Type `Tool.Context.cache_config` field as a proper typed map or struct instead of raw `map()` in `lib/deft/tool.ex`
