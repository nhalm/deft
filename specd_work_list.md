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

## orchestration v0.4

- Fix `Runner.reconcile` provider key mismatch (runner.ex:160): uses `Map.get(config, :provider, "anthropic")` which returns the module atom `Deft.Provider.Anthropic`, but `request_llm_call` (runner.ex:232) uses `Map.get(config, :provider_name, "anthropic")` which returns the string `"anthropic"`. RateLimiter debits the `"anthropic"` bucket on request but reconcile credits the `Deft.Provider.Anthropic` atom key — mismatched keys mean tokens are never credited back. Fix: change line 160 to use `:provider_name` instead of `:provider`.
