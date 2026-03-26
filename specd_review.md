# Review

## logging

**Finding:** Job abort logged at `:info`, spec §6 says `:error`
**Code:** `lib/deft/job/foreman.ex:720` logs `"Foreman aborting job"` at `:info`; `lib/deft/git/job.ex:1115` logs `"Job aborted - cleanup completed"` at `:info`
**Spec:** §6 Error level requires "Job abort"
**Options:** (A) Change to `:error` per spec — but abort is user-initiated, creating false alarms in log monitoring. (B) Keep `:info` and update spec to move "Job abort" from Error to Info. (C) Log the abort request at `:info` but log abort failures at `:error`.
**Recommendation:** Option C — the abort request itself is normal operation (`:info`), but if cleanup fails during abort, that's an error. Update spec §6 to move "Job abort" from Error to Info, and add "Job abort cleanup failures" to Error.
