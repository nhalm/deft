# Review

## logging

**Finding:** "Session saved" is required by spec §9 (Info level) but is not logged anywhere after being correctly removed from `Store.append/3`
**Code:** `Store.append/3` in `lib/deft/session/store.ex` no longer logs "Session saved" (removed because append is a low-level function called on every entry). No other caller logs it either.
**Spec:** Section 9 lists "Session saved" under Info level.
**Options:** (a) Remove "Session saved" from the spec — append is called too frequently for info-level logging, and there's no single meaningful "session saved" event. (b) Add the log to specific high-level callers that represent meaningful save points (but which ones?). (c) Redefine as debug-level rather than info.
**Recommendation:** Remove "Session saved" from the spec. Session persistence happens continuously via append — there's no discrete "save" event worth logging at info level. The "Session resumed" log already covers the meaningful lifecycle event.
