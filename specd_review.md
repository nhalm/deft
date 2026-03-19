# Review

## issues v0.2

**Finding:** Cycle detection on load clears dependencies of issues that merely *point into* a cycle, not just issues that are part of the cycle

**Code:** `detect_and_fix_cycles` (issues.ex:553-580) calls `has_cycle?` per issue, starting `visited` with the issue's own ID. For A→B→C→B, checking A traverses to B, then C, then finds B in visited → returns true for A. A's dependencies are cleared even though A is not in the cycle (B↔C is).

**Spec:** Section 3 (v0.2 changelog): "If a cycle is detected, the *affected issues* are logged as warnings and their dependencies are cleared."

**Options:**
1. "Affected" means only cycle members (B and C) — fix `has_cycle?` to only flag issues whose own ID appears in a cycle
2. "Affected" means any issue whose dependency graph is tainted by a cycle (current behavior) — this is defensible but destroys valid A→B dependency data

**Recommendation:** Option 1 — only clear dependencies of actual cycle members. A's dependency on B is legitimate and should be preserved. A will naturally be blocked until B is unblocked.
