# Rate Limiter

| | |
|--------|----------------------------------------------|
| Version | 0.2 |
| Status | Implemented |
| Last Updated | 2026-03-17 |

## Changelog

### v0.2 (2026-03-20)
- Added `job.max_leads` to configuration table — was referenced in section 5 but missing from section 7

### v0.1 (2026-03-17)
- Extracted from orchestration.md v0.2 — centralized rate limiting, priority queue, adaptive concurrency, cost tracking

## Overview

`Deft.Job.RateLimiter` is a GenServer that all LLM calls in a job flow through. It enforces per-provider rate limits using a dual token-bucket algorithm, manages a priority queue to prevent starvation, handles 429 errors with adaptive backoff, scales Lead concurrency based on capacity signals, and tracks cost against a configurable ceiling.

**Scope:**
- Dual token-bucket algorithm (RPM + TPM) per provider
- Priority queue with starvation protection
- 429 handling with capacity reduction and exponential backoff
- Adaptive concurrency (scale-up/scale-down signals)
- Cost tracking from API responses
- Cost ceiling with buffer

**Out of scope:**
- Provider API details (see [providers.md](providers.md))
- Job lifecycle and process architecture (see [orchestration.md](orchestration.md))
- Per-model pricing table maintenance

**Dependencies:**
- [providers.md](providers.md) — provider rate limits, API response format
- [orchestration.md](orchestration.md) — process architecture, Foreman/Lead/Runner hierarchy

**Design principles:**
- **Centralized control.** A single GenServer for all LLM calls in a job. No distributed rate limiting.
- **Priority without starvation.** Higher-priority callers go first, but no call waits indefinitely.
- **Adaptive, not static.** Concurrency adjusts based on actual capacity signals, not fixed configuration.
- **Graceful degradation.** 429s reduce capacity temporarily rather than failing the job.

## Specification

### 1. Dual Token-Bucket Algorithm

Each provider gets two token buckets:

- **RPM bucket** — requests per minute. Refills at the provider's RPM limit. Each LLM call deducts 1 token.
- **TPM bucket** — tokens per minute. Refills at the provider's TPM limit. Deducts estimated input tokens on send (`chars / 4` heuristic). On API response, reconciles actual usage: credits back `(estimated - actual)` to the bucket, capped at the bucket maximum (no over-crediting that would allow bursts above the configured TPM).

A call proceeds only when both buckets have sufficient capacity. If either is exhausted, the call is queued.

### 2. Priority Queue

**Priority order:** Foreman > Runner > Lead.

**Rationale for Runner > Lead:** Runners are spawned by Leads. A Lead waiting for its Runner's LLM response is blocked. Starving Runners starves Leads — this is priority inversion. Giving Runners higher priority than Leads ensures Leads' active work completes before Leads get to plan more work.

The Foreman has highest priority because its coordination decisions (unblocking, steering, conflict resolution) affect all Leads.

**Implementation:** A priority queue (e.g., `:gb_trees` or a sorted list) ordered by `{priority, enqueue_time}`. Calls are dequeued in priority order, with FIFO within the same priority level.

### 3. Starvation Protection

Lower-priority calls are promoted after waiting **10 seconds**. Specifically, any call waiting longer than 10 seconds is treated as having the highest priority. This ensures no call waits indefinitely, even under sustained high-priority load.

### 4. 429 Handling

When a rate limit error (HTTP 429) is received:

1. Parse `Retry-After` header if present; use it as the minimum wait time
2. **Reduce bucket capacity by 20%** for the affected provider — the provider's actual limit is lower than configured
3. Apply **exponential backoff** on the specific call (1s, 2s, 4s, 8s, ... capped at 60s)
4. **Restore capacity gradually** after 60 seconds without any 429s from that provider — increase capacity by 10% per minute until back to the configured limit

### 5. Adaptive Concurrency

Controls how many Leads the Foreman starts concurrently (not individual LLM call slots).

- **Starting point:** `job.initial_concurrency` (default 2) concurrent Lead slots
- **Scale-up signal:** Token bucket above 60% capacity for 30+ seconds with zero queued calls → add 1 Lead slot (up to `job.max_leads`)
- **Scale-down signal:** 429 rate exceeds 2 per minute → remove 1 Lead slot (minimum 1)

The RateLimiter sends `{:rate_limiter, :concurrency_change, new_limit}` to the Foreman when the concurrency limit changes. The Foreman decides whether to start or pause Leads accordingly.

### 6. Cost Tracking

Reads `usage` (input_tokens, output_tokens) from API responses. Multiplies by per-model pricing from a configurable pricing table.

**Reporting:** Sends `{:rate_limiter, :cost, amount}` to the Foreman every $0.50 increment. Uses the `{:rate_limiter, ...}` message format (not `{:lead_message, ...}`) since the RateLimiter is not a Lead.

**Cost ceiling:** Pauses the job at `cost_ceiling - $1.00` buffer to absorb in-flight overruns. In-flight calls complete (slight overshoot accepted); no new calls dispatched until the user approves continued spending.

### 7. Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `job.cost_ceiling` | `10.00` | Job pauses and asks user approval before exceeding ($) |
| `job.cost_warning` | `5.00` | Display warning in TUI when reached ($) |
| `job.initial_concurrency` | `2` | Starting number of concurrent Leads (adaptive scaling) |
| `job.max_leads` | `5` | Maximum concurrent Lead slots (upper bound for adaptive scaling) |

Provider-specific RPM/TPM limits are configured in [providers.md](providers.md).

## Notes

### Design decisions

- **Dual buckets over single.** RPM and TPM are independent constraints. A single bucket cannot model both — a few large requests could exhaust TPM while RPM has capacity, or many small requests could exhaust RPM while TPM is fine.
- **Runner > Lead priority.** This is counterintuitive but correct. Leads spawn Runners and block on them. Prioritizing Leads over Runners creates priority inversion — the Lead gets to plan more work but its existing work (Runners) starves.
- **20% capacity reduction on 429.** Conservative enough to avoid oscillation, aggressive enough to stop repeated 429s. The gradual restore (10% per minute) prevents capacity from snapping back too fast.
- **$1.00 buffer before ceiling.** In-flight LLM calls can cost $0.10-$0.50 each. A $1.00 buffer gives enough room for several in-flight calls to complete without exceeding the ceiling.

## References

- [orchestration.md](orchestration.md) — job lifecycle, process architecture
- [providers.md](providers.md) — provider API details, rate limits
