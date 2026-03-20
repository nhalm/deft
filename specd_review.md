# Review

## sessions

**Finding:** `deft resume <session-id>` without `-p` flag does not actually resume the session
**Code:** Without `-p`, `execute_command({:resume_session, session_id}, flags)` displays a session summary and returns `:ok` (cli.ex:560-567). No agent loop or TUI is started.
**Spec:** Section 5.1 lists `deft resume <session-id> | Resume a specific session` — implying the session should be actively resumed, not just displayed.
**Options:** (A) Start the TUI with restored session state when no `-p` flag is given; (B) Keep current behavior and clarify spec that `resume` without `-p` is informational only.
**Recommendation:** Option A — `deft resume <id>` should start the TUI with the restored conversation, matching user expectation of "resume."
