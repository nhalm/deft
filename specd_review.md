# Review

## orchestration v0.7

**Finding:** ForemanAgent and LeadAgent LLM calls bypass the RateLimiter entirely
**Code:** `lib/deft/agent.ex` has zero calls to `RateLimiter.request` or `RateLimiter.reconcile`. Only `lib/deft/job/runner.ex` (lines 188, 241) integrates with RateLimiter.
**Spec:** Orchestration spec section 1: "All LLM calls flow through `Deft.Job.RateLimiter`." Changelog v0.5: "Foreman and Lead must call `RateLimiter.reconcile/4` after each LLM response."
**Options:** (A) Add RateLimiter integration to `Deft.Agent` (touches harness spec scope), (B) Add a RateLimiter wrapper around the provider call in orchestration-specific agent configs, (C) Update the orchestration spec to acknowledge this is the rate-limiter/harness spec's responsibility.
**Recommendation:** Option A — `Deft.Agent` should optionally accept a `rate_limiter` config and call `request/reconcile` around provider calls. This keeps the integration in one place. Requires a harness spec update (new optional config field) and orchestration just passes the RateLimiter PID through.
