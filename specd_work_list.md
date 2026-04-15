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

## harness v0.5

- Verify `lib/deft/agent.ex` `retryable_error?/1` and its call sites in `handle_calling_error/2` and `handle_stream_error/2` match harness.md v0.5 §2 "Error recovery": retries fire only for 5xx, network failures, HTTP 408, and HTTP 429; all other 4xx surface immediately without retry. Confirm by reading the code and (if useful) adding a unit test that asserts `retryable_error?/1` returns false for a 400/401/403/404 message and true for 408/429/500/503/network errors. Done state: behavior matches spec wording exactly.
