# Review

## harness

**Finding:** `%Done{}` event silently dropped in `:calling` state
**Code:** agent.ex:283-354 — `:calling` handler has no `%Done{}` clause. Falls through to catch-all at line 352 (`_ -> :keep_state_and_data`). Recovery happens via `:DOWN` handler at line 380, which broadcasts "Stream process crashed: :normal" — misleading for a clean empty response.
**Spec:** harness.md section 2 — `:calling` transitions to `:streaming` (first chunk) or `:idle` (error). No defined behavior for "stream completes without content."
**Options:** (a) Add `%Done{}` handler in `:calling` that transitions to `:idle` cleanly, (b) Update spec to document this edge case, (c) Accept current behavior since empty LLM responses are extremely rare
**Recommendation:** Option (a) — add a `%Done{}` handler in `:calling` that calls `handle_idle_transition` without the error broadcast. Low effort, eliminates misleading error message.

## sessions

**Finding:** System prompt missing spec-required observation conflict resolution rule
**Code:** system_prompt.ex:182-205 — `build_conflict_resolution_rules/0` has 5 generic rules. None mention observations.
**Spec:** sessions.md section 3, item 5 — "If observations conflict with current messages, messages take precedence. If observations conflict with project instructions, project instructions take precedence."
**Options:** (a) Add the observation conflict rule now, even though OM is not implemented, (b) Defer until OM implementation and add a blocked work item, (c) Move the rule from sessions spec to OM spec since it only matters when observations exist
**Recommendation:** Option (b) — add as blocked work item under observational-memory. Including rules about a nonexistent feature would confuse the LLM.
