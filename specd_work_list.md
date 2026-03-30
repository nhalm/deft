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

## standards v0.4

- Fix test session leak in `test/deft/agent_test.exs`: the "sub-agent mode event broadcasting" test (line ~735) starts an Agent without `working_dir` in config, so `File.cwd!()` resolves to the repo root and session files land in the real project's sessions directory. Fix: create a temp dir, pass `working_dir: tmp_dir` in the agent config, and add `on_exit` cleanup to remove the temp dir.
- Delete 156 leaked test session files (`sub_agent_test_*` and `test_session_*`) from `~/.deft/projects/Users-nickhalm-personal-memory/sessions/`. These are artifacts from the unfixed test above. Clean up by removing matching files in the sessions directory.
