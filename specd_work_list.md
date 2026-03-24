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

## web-ui v0.2

- Apply `roster-hidden` class dynamically to `chat-container` div based on `@roster_visible` and `@job_active` assigns: use `class={"chat-container #{unless @roster_visible or @job_active, do: "roster-hidden"}"}`. Currently the class is static and the `.chat-container.roster-hidden` CSS rules are dead code.
- Handle nil `session_id` at mount in `ChatLive`: when `params["session"]` is nil (direct visit to `/`, session picker `q` key, `/quit` redirect), redirect to `/sessions` instead of proceeding with nil. Currently nil session_id causes crashes on prompt submission (`Worker.agent_via_tuple(nil)`) and Ctrl+C abort.
- Clear `active_tools` map when a new turn starts or previous turn ends in `ChatLive`: add reset logic in the `:state_change` handler. Currently tool calls accumulate across all turns and are never removed, showing stale tools from previous turns indefinitely.
- Add `handle_info` for `{:agent_event, {:turn_limit_reached, count, max}}` in `ChatLive`: display a message like "Turn limit reached (X/Y)" and provide a way for the user to call `Deft.Agent.continue_turn/2` or abort. Without this, the agent blocks permanently when the turn limit is hit.
- Fix slash command args: change `args = if args == [], do: "", else: List.first(args)` to `args = if args == [], do: nil, else: List.first(args)` at `chat_live.ex` line 527. Empty string `""` causes `inject_skill/3` to send a spurious empty user message to the agent after every no-arg command (`/status`, `/plan`, `/observations`, etc.).
