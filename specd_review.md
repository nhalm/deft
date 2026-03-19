# Review

## orchestration

**Finding:** No `Deft.Job.Supervisor` supervision tree — Foreman, Store, RateLimiter, and LeadSupervisor are started inline without OTP supervision
**Code:** Foreman starts Store inline in `init/1` (foreman.ex:215-221), Leads started via `Lead.start_link` directly (not under a DynamicSupervisor). No `Deft.Job.Supervisor` or `Deft.Job.LeadSupervisor` exists.
**Spec:** Section 1 defines a `Deft.Job.Supervisor (one_for_one)` tree with Store, RateLimiter, Foreman, and LeadSupervisor (DynamicSupervisor) as children.
**Options:** (A) Add the full supervision tree as spec prescribes. (B) Keep inline starts with explicit cleanup (current approach works for normal flow, fails on crashes). (C) Add supervision tree but with `restart: :temporary` for all children since jobs are one-shot.
**Recommendation:** Option C — add supervision tree with `:temporary` restart. This gives OTP-managed cleanup without restart loops, matching the job lifecycle.

