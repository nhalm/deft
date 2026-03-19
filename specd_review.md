# Review

## orchestration

**Finding:** Lead tool set prevents direct compile checks after each Runner
**Code:** Lead's `execute_tool` (lead.ex:731) and `call_llm` (lead.ex:783) hardcode read-only tools: `[Read, Grep, Find, Ls]`. No `bash` tool available.
**Spec:** Section 4.2 says the Lead "runs compile checks after each Runner" as part of its active steering responsibilities.
**Options:** (a) Add `bash` to Lead's tool set so it can run compile checks directly. (b) Clarify spec that "runs compile checks" means "spawns a testing Runner for compile checks." (c) Add a dedicated compile-check helper that the Lead calls without needing full bash access.
**Recommendation:** Option (b) — clarify spec wording. Leads are designed as managers that delegate execution to Runners. Adding bash would blur the Lead/Runner boundary. The Lead should spawn a lightweight testing Runner for compile checks.