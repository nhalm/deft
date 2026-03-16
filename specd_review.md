# Review

---

## sessions

**Finding:** `deft` and `deft resume <id>` CLI commands are stubs — they don't start an agent, display a conversation summary, or allow user interaction.

**Code:** `lib/deft/cli.ex:188-216` — both commands print a message and return `:ok` without starting an agent or wiring the reconstructed session state.

**Spec:** Sessions spec section 5.1 defines `deft` (start new session) and `deft resume <session-id>` (resume specific session). Section 1.3 requires displaying a conversation summary on resume.

**Options:**
1. Implement a minimal REPL-style interactive mode (readline-based input, raw terminal output) that works without TUI — unblocks these commands immediately
2. Mark both commands as blocked on TUI spec (Draft) — accept that interactive mode requires TUI
3. Implement only `deft resume <id>` with a summary display and a prompt for non-interactive continuation (`deft resume <id> -p "continue with..."`)

**Recommendation:** Option 3 — implement resume summary display and allow non-interactive continuation. A full interactive mode should wait for TUI, but resume + summary + non-interactive continuation is useful for the bootstrap phase and doesn't require TUI.
