# Review

## logging

**Finding:** Spec §4 requires "Provider stream complete (duration, status code)" but `%Provider.Done{}` is an empty struct — the HTTP status code is not propagated through the provider event pipeline.
**Code:** `lib/deft/agent.ex:961` logs duration only. `lib/deft/provider.ex:270` defines `Done` as `defstruct []`. The status code is consumed inside `anthropic.ex` stream_loop but never forwarded.
**Spec:** §4 Info level — "Provider stream complete (duration, status code)"
**Options:** (A) Extend `%Done{}` to carry the status code and have anthropic.ex populate it. (B) Remove "status code" from the spec — by the time streaming completes successfully, the status was always 200; non-200 statuses surface as errors handled separately.
**Recommendation:** Option B — remove "status code" from the stream complete log requirement. A successful stream completion inherently means 200. Non-200 responses are already logged at error level as provider failures.
