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

## orchestration v0.7

- Fix site log name passed to Lead: Foreman passes bare tuple `{:sitelog, session_id}` (foreman.ex:982) but Store registers via `{:via, Registry, {Deft.ProcessRegistry, {:sitelog, session_id}}}` — Lead's `Store.tid/1` call fails silently, so Lead never reads site log context (research, contracts, decisions are always empty)
- Fix site log metadata key mismatch: Foreman writes `category: type` (foreman.ex:1068) but Lead reads `entry[:metadata][:type]` (lead.ex:605) — always nil, so all site log entries are silently dropped even after the name fix above (blocked: site log name fix)

