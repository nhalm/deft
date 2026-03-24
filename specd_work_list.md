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

## web-ui v0.4

- Fix `render_conversation_item/1` error branch in chat_live.ex:653: returns plain `content` string instead of `HTML.raw(html)`. Earmark's `{:error, html, messages}` tuple includes rendered HTML in the second element, but the code ignores it (`_html`) and returns the raw markdown string. Phoenix templates HTML-escape plain strings, so error-branch content renders with visible `&lt;`/`&gt;` entities. Fix: change `{:error, _html, _messages} -> content` to `{:error, html, _messages} -> HTML.raw(html)`.
- Implement force-abort for double Ctrl+c in chat_live.ex:392-396: both single and double Ctrl+c call `Deft.Agent.abort(agent)`. Spec §6.4 requires double Ctrl+c to force-abort. Need `Deft.Agent.force_abort/1` (or equivalent) that kills the agent process immediately rather than requesting graceful abort. (blocked: harness — Agent module needs force_abort/1)
