# Review

## issues v0.3

**Finding:** SIGINT timeout behavior contradicts spec — code rolls back issue status instead of leaving it at `:in_progress`
**Code:** `handle_job_result({:error, :sigint_timeout}, ...)` at cli.ex:2232-2249 calls `Issues.update(issue.id, %{status: :open})` to manually roll back
**Spec:** §5.3: "waits for the current issue's status to be rolled back to :open (with a 5-second timeout), then exits. If the timeout expires, the issue is left at `:in_progress`"
**Options:** (A) Update code to leave issue at `:in_progress` on timeout, matching spec's stale-detection design. (B) Update spec to match code's always-rollback behavior.
**Recommendation:** Option B — the code's behavior is safer (prevents orphaned `:in_progress` issues). Update spec to say "On timeout, manually rolls back to `:open` with a warning."
