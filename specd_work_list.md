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

- Add `/correct` command handling in Foreman: parse `/correct <message>` from user prompts, write correction to site log via `promote_lead_message_to_site_log(:correction, ...)`, then forward to ForemanAgent — currently all user prompts are forwarded as-is with no site log write (foreman.ex:503-545, spec sections 7.2, 7.3, 8.2)
- Add cost ceiling monitoring in Foreman: handle `{:rate_limiter, :cost_warning, cost}` messages from RateLimiter, pause execution when approaching ceiling, notify user for approval — currently no handler exists and cost warnings are silently dropped (spec section 4.6, 7.2; rate_limiter.ex:646-651 sends the message but foreman.ex has no receiver)

