# Review

## observational-memory

**Finding:** OM persistence writes to a separate file instead of the session JSONL as specified.
**Code:** `lib/deft/om/state.ex:1737-1741` — writes to `<session_id>_om.jsonl` via `om_snapshot_path/1`
**Spec:** Section 9 says "OM state is persisted as `observation` entries in the session JSONL file (from harness spec)."
**Options:** (A) Update spec section 9 to specify separate OM file (matching code). (B) Refactor code to write observation entries into the session JSONL.
**Recommendation:** Update spec. The separate file was a deliberate choice (specd_history.md: "use separate OM snapshot file to avoid JSONL write interleaving"). Writing to the session JSONL would require coordinating writes between the session store and OM state, adding complexity for no functional benefit.
