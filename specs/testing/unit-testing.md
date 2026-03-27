# Unit Testing

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Ready |
| Last Updated | 2026-03-27 |

## Changelog

### v0.1 (2026-03-27)
- Initial spec — unit testing philosophy, critical path coverage, ScriptedProvider integration scenarios

## Overview

Defines what unit and integration tests Deft needs and how they should be structured. This is a lightweight spec — it describes the philosophy, the critical paths that must be covered, and the ScriptedProvider-based integration scenarios. It does not enumerate every test case for every module.

Component-specific deep-dive specs can be added later as `specs/testing/<component>-testing.md` when a component needs more detailed test planning.

**Scope:**
- What must be unit tested across all components
- ScriptedProvider integration test scenarios
- Test infrastructure patterns (setup, teardown, mocking)
- Existing coverage inventory (what we have today)

**Out of scope:**
- Eval test cases (see [evals/](evals/))
- Per-module exhaustive test case lists (future per-component specs)
- CI pipeline configuration

**Dependencies:**
- [README.md](README.md) — testing strategy, three-layer model, ScriptedProvider design
- [../harness.md](../harness.md) — agent loop states and transitions
- [../orchestration.md](../orchestration.md) — Foreman/Lead/Runner architecture
- [../providers.md](../providers.md) — provider behaviour

## Specification

### 1. Unit Test Expectations

Unit tests cover deterministic OTP mechanics. They answer: "given this state and this event, does the right thing happen?"

#### 1.1 Agent Loop (Harness)

Critical paths:
- State transitions: `:idle` → `:calling` → `:streaming` → `:executing_tools` → `:idle`
- Prompt queueing: prompt received while not `:idle` is queued and delivered after current turn
- Abort: works in all states (`:calling`, `:streaming`, `:executing_tools`), cleans up in-flight work
- Turn limit: enforced after N consecutive LLM calls, pauses for user confirmation
- Error recovery: provider errors trigger retry with backoff, exhaust retries → `:idle` with error

#### 1.2 Foreman

Critical paths:
- **Site log promotion:** auto-promote `decision`, `contract`, `correction`, `critical_finding`; promote `finding` only when `shared: true`; never promote `status`, `blocker`
- **Lead crash cleanup:** `:DOWN` message → remove Lead from tracking, clean up worktree (graceful on failure)
- **Research phase:** spawns Runners, collects findings, handles timeout (preserves partial findings)
- **Decomposition phase:** plan approval transitions to `:executing`, rejection adds revision prompt
- **Partial unblocking:** contract message → check blocked Leads → start unblocked Lead
- **Conflict detection:** overlapping decisions from concurrent Leads → pause and resolve
- **Cost ceiling:** rate limiter cost event → pause new Lead spawning
- **Single-agent fallback:** simple task detection skips orchestration

#### 1.3 Lead

Critical paths:
- Receives deliverable assignment and decomposes into Runner tasks
- Spawns Runners via Task.Supervisor, tracks completion
- Handles Runner crash/timeout without crashing itself
- Sends correct message types to Foreman (`:status`, `:decision`, `:contract`, `:complete`)
- Handles `:foreman_steering` messages mid-execution

#### 1.4 Observational Memory

Critical paths:
- Observer activation at token threshold
- Reflector activation at observation threshold
- Section-aware merge (Current State replaced, others appended, dedup on Files & Architecture)
- CORRECTION marker preservation through reflection
- Async buffering: pre-computed chunks activated instantly at threshold
- Sync fallback: forced observation/reflection when async falls behind
- Persistence: snapshot saved after activation, loaded on resume

#### 1.5 Store (ETS+DETS)

Critical paths:
- Read/write/delete operations
- Lazy DETS flush at buffer threshold
- Persistence across restarts
- Key listing

#### 1.6 Rate Limiter

Critical paths:
- Dual token-bucket (RPM + TPM) deduction
- Reconciliation with actual usage (credit-back capping)
- Multi-provider independence

### 2. Integration Test Scenarios (ScriptedProvider)

These tests use ScriptedProvider (see [README.md](README.md) section 2) to drive realistic multi-turn agent interactions without real LLM calls.

#### 2.1 Single-Agent Turn Loop

Scripted: assistant responds with tool call → tool executes → assistant responds with text.
Verify: agent transitions through `:calling` → `:streaming` → `:executing_tools` → `:calling` → `:streaming` → `:idle`. Messages accumulated correctly. Events broadcast via Registry.

#### 2.2 Foreman Research → Decompose → Execute

Scripted: planning response with research tasks → research Runner responses → decomposition response with deliverables and DAG.
Verify: Foreman transitions through phases. Research findings stored. Plan written to site log. Leads started in dependency order.

#### 2.3 Partial Unblocking Flow

Scripted: Lead A publishes contract → Foreman receives → Lead B starts with contract context.
Verify: Lead B's starting context includes the contract from Lead A. Lead B started before Lead A completes.

#### 2.4 Resume from Saved State

Setup: persist a mid-job state (site log + plan.json + completed deliverables). Start a new Foreman with `resume: true`.
Verify: Foreman reads persisted state. Only incomplete deliverables get fresh Leads. Completed work is not repeated.

#### 2.5 Rate Limiter Integration

Scripted: provider responses with usage metadata.
Verify: RateLimiter.request/4 called before each LLM call. RateLimiter.reconcile/4 called after. Credit-back works. Cost ceiling triggers pause.

#### 2.6 Observation Injection

Scripted: multi-turn conversation that crosses observation threshold.
Verify: Observer fires. Observations injected into next LLM call's context. Observed messages trimmed from history. Continuation hint present.

### 3. Existing Coverage Inventory

What we have today in `test/`:

| Component | File | Tests | Coverage |
|-----------|------|-------|----------|
| Foreman | `test/deft/job/foreman_test.exs` | 19 | Site log promotion, Lead crash cleanup, research phase, decomposition phase |
| Agent | `test/deft/agent_test.exs` | — | Basic agent loop, abort |
| Store | `test/deft/store_test.exs` | — | CRUD, lazy flush, persistence |
| RateLimiter | `test/deft/job/rate_limiter_test.exs` | — | Dual bucket, reconciliation |
| OM State | `test/deft/om/state_test.exs` | — | Buffered chunks, token thresholds |
| Session Store | `test/deft/session/store_test.exs` | — | JSONL append, roundtrip |
| Tools | `test/deft/tools/*.exs` | — | Bash, Edit (per-tool) |
| ChatLive | `test/deft_web/live/chat_live_test.exs` | — | LiveView mount, events |

### 4. Coverage Gaps

Missing unit tests (known):
- Foreman partial unblocking logic
- Foreman conflict detection between Leads
- Foreman cost ceiling enforcement
- Foreman single-agent fallback decision
- Lead Runner spawning and crash handling
- Lead steering message handling
- OM section-aware merge edge cases
- OM sync fallback path

Missing integration tests (all — ScriptedProvider doesn't exist yet):
- All scenarios in section 2

## Notes

### Design decisions

- **Lightweight spec, not exhaustive.** This spec names critical paths and scenarios. Per-module test case lists are better discovered during implementation than pre-planned in a spec.
- **ScriptedProvider is the highest-priority gap.** Without it, integration tests are impossible and unit tests can only verify error paths. Building it unlocks the entire integration layer.
- **Existing tests are solid foundations.** The 19 Foreman unit tests cover the most important OTP mechanics. The gap is in integration (ScriptedProvider) and missing unit tests for partial unblocking, conflict detection, and cost management.

## References

- [README.md](README.md) — testing strategy, ScriptedProvider design
- [evals/foreman.md](evals/foreman.md) — Foreman eval test cases
- [evals/lead.md](evals/lead.md) — Lead eval test cases
- [../harness.md](../harness.md) — agent loop
- [../orchestration.md](../orchestration.md) — Foreman/Lead/Runner
