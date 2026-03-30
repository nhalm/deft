# Review

## logging

**Finding:** `Store.append/3` and `Store.append_to_path/2` log errors internally (`Logger.error` at `lib/deft/session/store.ex:66` and `:94`), violating the "only callers log" principle for file I/O. However, the primary caller (`Agent`) explicitly discards the return value (`_ = Store.append(...)`), meaning removing the internal log would make append failures completely invisible.
**Code:** `lib/deft/session/store.ex:64-68` and `:92-96` — `Logger.error` in error path of `append/3` and `append_to_path/2`
**Spec:** §9 / Design principles: "Only callers log. Low-level functions return deterministic results. They do not log. This applies to... file I/O."
**Options:** (a) Remove error log from append, fix Agent to handle the error return; (b) Remove error log from append, accept silent failure since session append isn't critical; (c) Keep the error log as a pragmatic exception to the principle
**Recommendation:** Option (a) — fix the Agent to at least log at warning level when append fails, then remove the internal log. This respects the principle and keeps failures visible.
