# Review

## sessions

**Finding:** Interactive session mode (`deft` with no args) is a TODO stub
**Code:** `execute_command(:new_session, _flags)` at cli.ex:248-253 prints "Interactive mode not yet implemented" and exits
**Spec:** Section 5.1 says `deft` should "Start a new session in the current directory"
**Options:** (1) Implement a minimal REPL-style interactive mode using IO.gets in a loop, independent of TUI. (2) Mark as blocked on tui.md and defer until TUI is implemented. (3) Remove from sessions spec and move to tui spec.
**Recommendation:** Option 2 — the spec's section 5.2 says "In non-interactive mode, no TUI is started", implying the regular mode uses TUI. Defer until tui.md is Ready.
