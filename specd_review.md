# Review

## providers

**Finding:** Spec event mapping says `content_block_start (type: text)` → `:text_delta (first chunk)` and `content_block_start (type: thinking)` → `:thinking_delta (first chunk)`, but code emits nothing for these events.
**Code:** `parse_content_block_start/1` returns `:skip` for text and thinking blocks (anthropic.ex:317-323). `handle_content_block_start/3` also skips them (anthropic.ex:187-189).
**Spec:** Section 4 SSE event mapping table explicitly maps these to delta events.
**Options:** (1) Emit empty deltas on content_block_start to match spec. (2) Update spec mapping table to note that Anthropic sends empty content in content_block_start, so the first real delta comes from content_block_delta.
**Recommendation:** Update the spec mapping table — Anthropic's API doesn't include text content in content_block_start events, so emitting empty deltas adds noise. The code is correct.

## sessions

**Finding:** Spec says project instructions are in the system prompt (section 3.5) AND in context assembly as item 4 (section 4.1.4). Code puts them only in context assembly.
**Code:** `SystemPrompt.build/1` (system_prompt.ex) does NOT include project files. `Context.build/2` (context.ex:66-81) appends project context as a separate system message.
**Spec:** Section 3 item 5 says system prompt includes "Project instructions — contents of DEFT.md / CLAUDE.md / AGENTS.md". Section 4.1 item 4 says context assembly includes "Project context — contents of DEFT.md, CLAUDE.md, or AGENTS.md".
**Options:** (1) Include project instructions in the system prompt string (section 3.5) and remove from context assembly item 4. (2) Keep them only in context assembly (current behavior) and update section 3 to remove item 5. (3) Include in both places (redundant tokens).
**Recommendation:** Keep in context assembly only (option 2) — project files can be large and belong as a separate message for easier context management. Update spec section 3 to remove project instructions from the system prompt list.
