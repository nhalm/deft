# Review

## git-strategy

**Finding:** Foreman hardcodes `auto_approve: true` when calling `GitJob.create_job_branch`, making the stash-prompt path unreachable. Dirty working tree always fails the job.
**Code:** `foreman.ex:393` passes `auto_approve: true`; `git/job.ex:94-105` returns `{:error, :dirty_working_tree}` in auto mode
**Spec:** Section 1 says "verify the working tree is clean. If uncommitted changes exist, warn the user and ask to stash."
**Options:** (A) Move stash prompt to CLI/TUI before starting Foreman, (B) Have Foreman send a message to TUI requesting stash approval, (C) Auto-stash in Foreman without prompting
**Recommendation:** Option A — the Foreman is a GenServer that can't do interactive I/O; stash prompt belongs in the CLI/TUI layer before Foreman.start_link
