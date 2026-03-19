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

- Fix Lead config key mismatch: `Map.get(data.config, :runner_timeout, 300_000)` at lead.ex:524,1064 and `Map.get(data.config, :max_runners_per_lead, 3)` at lead.ex:1243 read non-existent keys from the Config struct (which has `:job_runner_timeout` and `:job_max_runners_per_lead`); `Map.get` returns nil and falls to the hardcoded default; user-configured runner timeout and max runners per lead are silently ignored
- Fix Runner `unless provider` guard: `unless provider do {:error, "No provider configured"} end` at runner.ex:99-101 discards its return value; execution continues with nil provider, crashing at `provider.stream/3` with a misleading `UndefinedFunctionError`; use early return (`if is_nil(provider), do: raise ...` or pattern match) to halt before `loop/8`
- Fix Lead crash falsely satisfying `all_leads_complete?`: when a Lead crashes (foreman.ex:1059-1098), it is removed from `data.leads` but remains in `data.started_leads`; `all_leads_complete?` checks `started_count == deliverables_count and remaining_leads == 0`, which is satisfied even though the crashed Lead's deliverable is incomplete; Foreman transitions to `:verifying` with missing work; either track failed deliverables separately or check that all started deliverables have a corresponding merge/completion record
- Fix `provider_name` key mismatch in Foreman and Lead `call_llm`: `Map.get(config, :provider_name, "anthropic")` at foreman.ex:1127 and lead.ex:776 reads a non-existent key from the Config struct (which has `:provider`); always falls to "anthropic" default; user-configured provider name is ignored in RateLimiter calls
