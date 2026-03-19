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

- Add recovery path for Lead crash and Lead start failure: after `fc68dda` added `completed_count == deliverables_count` to `all_leads_complete?`, crashed/failed-to-start Leads never write a `:complete` marker, so the job permanently hangs. Either write a failure marker that `all_leads_complete?` accounts for, or reduce `deliverables_count` to exclude failed deliverables.
- Fix Runner rate limiter provider key: Runner passes module atom (`Deft.Provider.Anthropic`) as provider name to `RateLimiter.request` (runner.ex:232) because `runner_config[:provider]` is set to `get_provider(data)` (a module). Lead/Foreman pass string `"anthropic"` from Config struct. Separate bucket sets are created, defeating centralized rate limiting. Normalize to the same key in both paths.
- Fix Runner `execute_tools_inline` (runner.ex:357-446) to return a single `%Message{role: :user}` containing all `%ToolResult{}` content blocks. Currently returns one `%Message{role: :user}` per tool result, creating consecutive user messages on multi-tool turns — violates Anthropic API alternating-role requirement and causes API errors.
