# Testing Strategy

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Implemented |
| Last Updated | 2026-03-27 |

## Changelog

### v0.1 (2026-03-27)
- Initial spec — testing philosophy, three-layer strategy, ScriptedProvider design, coverage expectations

## Overview

Testing strategy for Deft. Defines how we validate that Deft works correctly across three layers: deterministic unit tests, integration tests with scripted LLM responses, and LLM-powered evals that measure output quality.

The goal is not 100% coverage — it's confidence in critical paths. Every test should justify its existence by covering a behavior that would be expensive to debug if broken.

**Scope:**
- Testing philosophy and what we expect from each layer
- ScriptedProvider — the mock that enables integration testing without real LLM calls
- Coverage expectations (what must be tested vs what's fine without tests)
- How the three layers relate to each other

**Out of scope:**
- Specific eval test case definitions (see [evals/](evals/))
- Specific unit test definitions for individual components (future per-component specs)
- CI pipeline configuration
- Eval result storage and regression detection (see [evals/README.md](evals/README.md))

**Dependencies:**
- [evals/README.md](evals/README.md) — eval infrastructure, Tribunal, fixtures, pass rates
- [../harness.md](../harness.md) — agent loop, gen_statem states
- [../orchestration.md](../orchestration.md) — Foreman/Lead/Runner architecture
- [../providers.md](../providers.md) — provider behaviour that ScriptedProvider implements
- [../standards.md](../standards.md) — Elixir coding standards, Makefile, test tags

**Design principles:**
- **Test critical paths, not everything.** State machine transitions, message routing, safety checks, and LLM judgment quality. Not getters, formatters, or simple pass-through functions.
- **Each layer has a job.** Unit tests catch OTP bugs. Integration tests catch multi-process coordination bugs. Evals catch LLM quality regressions. Don't use evals to test what a unit test can cover.
- **Isolation over integration by default.** Test the smallest unit that exercises the behavior. Only go wider when the behavior spans multiple processes.
- **Flaky tests are worse than no tests.** If a test fails non-deterministically, fix or delete it. LLM variance belongs in evals with statistical pass rates, not in unit tests.

## Specification

### 1. Three Testing Layers

| Layer | What it tests | LLM calls? | Speed | When to run |
|-------|--------------|------------|-------|-------------|
| **Unit** | OTP mechanics, state transitions, message routing, data transforms | No | Fast (<1s per test) | Every push |
| **Integration** | Multi-process coordination, realistic agent turns via ScriptedProvider | No (scripted) | Medium (~5s per test) | Every push |
| **Eval** | LLM output quality — decomposition, extraction, steering, judgment | Yes (real API) | Slow (~$2-15 per suite) | Tiered (see [evals/README.md](evals/README.md)) |

#### 1.1 Unit Tests

Unit tests validate deterministic behavior. They use mocks for external dependencies (providers, git) and `:sys.get_state` / `:sys.replace_state` for gen_statem introspection.

**What belongs here:**
- State machine transitions (phase A + event → phase B)
- Message routing (Lead message type → correct site log promotion)
- Error handling (crash recovery, timeout handling, graceful degradation)
- Data transforms (plan parsing, contract extraction, message formatting)
- Configuration defaults and overrides

**What doesn't belong here:**
- Testing that the LLM produces good output (that's an eval)
- Testing multi-process coordination end-to-end (that's integration)
- Testing trivial code (simple accessors, pass-through functions)

**Patterns:**
- Start real gen_statem processes, use `:sys` for introspection
- `ProviderMock` (always fails) for tests that don't need LLM responses
- `GitMock` (configurable responses) for tests involving worktree operations
- `send()` to simulate messages from other processes
- Temp directories for file-based state (DETS, JSONL), cleaned up in `on_exit`

#### 1.2 Integration Tests

Integration tests validate multi-process coordination with realistic but deterministic LLM responses. The key enabler is the **ScriptedProvider** (section 2).

**What belongs here:**
- Full phase transitions (planning → researching → decomposing → executing)
- Foreman + Lead coordination over OTP messages
- Partial unblocking flow (contract published → dependent Lead starts)
- Resume from persisted state
- Rate limiter integration (request/reconcile cycle)

**What doesn't belong here:**
- Testing LLM judgment quality (that's an eval)
- Testing isolated state transitions (that's a unit test)

#### 1.3 Evals

Evals validate LLM output quality using real API calls, statistical pass rates, and LLM-as-judge assertions. See [evals/README.md](evals/README.md) for infrastructure details and component eval specs in `evals/`.

### 2. ScriptedProvider

A test-only provider implementation that returns pre-defined responses in sequence. This is the missing piece that enables integration testing without real LLM calls.

#### 2.1 Behaviour

`ScriptedProvider` implements the `Deft.Provider` behaviour. It is configured with an ordered list of responses. Each `stream/3` call consumes the next response from the list.

```
ScriptedProvider.start_link(responses: [
  %{text: "I'll research the codebase.", tool_calls: [%{name: "grep", args: %{...}}]},
  %{text: "Based on my research, here's the plan.", tool_calls: []},
  ...
])
```

#### 2.2 Response Format

Each scripted response specifies:
- `text` — assistant text content
- `tool_calls` — list of tool call blocks (name, args)
- `thinking` — optional thinking block content
- `usage` — optional token usage (for rate limiter / cost tracking tests)
- `delay_ms` — optional delay before responding (for timeout tests)
- `error` — optional error to return instead of a response (for retry tests)

#### 2.3 Streaming Simulation

ScriptedProvider emits response chunks via the same streaming protocol as real providers. This ensures the agent's stream handling code is exercised. Responses are chunked at word boundaries with minimal delay (no artificial latency unless `delay_ms` is set).

#### 2.4 Assertions

ScriptedProvider records all calls for assertion:
- `ScriptedProvider.calls(pid)` returns the list of `{messages, tools, config}` tuples received
- `ScriptedProvider.assert_called(pid, n)` asserts exactly `n` calls were made
- `ScriptedProvider.assert_exhausted(pid)` asserts all scripted responses were consumed

If `stream/3` is called after all responses are consumed, it returns `{:error, :no_more_responses}` — this is a test failure, not a graceful fallback.

### 3. Coverage Expectations

We don't target a coverage percentage. Instead, we define categories of behavior that **must** have tests and categories where tests are optional.

#### 3.1 Must Test

| Category | Layer | Why |
|----------|-------|-----|
| State machine transitions | Unit | A wrong transition can deadlock the agent |
| Message routing and site log promotion | Unit | Wrong promotion policy corrupts shared knowledge |
| Crash recovery and cleanup | Unit | Resource leaks from unhandled crashes |
| Timeout handling | Unit | Hung processes block the entire job |
| Partial unblocking logic | Unit/Integration | Wrong unblocking breaks the dependency DAG |
| Conflict detection between Leads | Unit | Undetected conflicts produce inconsistent code |
| Cost ceiling enforcement | Unit | Runaway costs with no user control |
| Resume from persisted state | Integration | Resume failures lose completed work |
| ScriptedProvider multi-turn flows | Integration | Validates the full turn loop without LLM cost |
| Work decomposition quality | Eval | Bad decomposition cascades through entire job |
| Verification accuracy (circuit breaker) | Eval | False positives mark broken work as done |

#### 3.2 Test When Complex

Behaviors that should be tested when the implementation is non-obvious, but can be skipped for straightforward code:
- Configuration parsing and defaults
- Plan serialization/deserialization
- Log formatting

#### 3.3 Don't Test

- Simple struct construction or field access
- Pass-through functions that delegate to a single dependency
- Phoenix route declarations (covered by integration tests)
- Code that only formats strings for display

### 4. Test Tags

All tests are tagged for selective execution:

| Tag | Meaning | Included in `make test`? |
|-----|---------|--------------------------|
| (none) | Unit test | Yes |
| `@tag :integration` | Multi-process integration test | No (`make test.integration`) |
| `@tag :eval` | LLM-powered eval | No (`make test.eval`) |
| `@tag :expensive` | Multiple LLM calls | No |
| `@tag :e2e` | Full end-to-end | No |
| `@tag :holdout` | Eval holdout set | No (`make test.eval.holdout`) |

## Included Specs

| Spec | Description |
|------|-------------|
| [unit-testing](unit-testing.md) | Unit testing philosophy, ScriptedProvider scenarios, coverage expectations per component |
| [evals/README](evals/README.md) | AI eval infrastructure — Tribunal, fixtures, pass rates, regression detection |
| [evals/observer](evals/observer.md) | Observer eval test cases |
| [evals/reflector](evals/reflector.md) | Reflector eval test cases |
| [evals/actor](evals/actor.md) | Actor eval test cases |
| [evals/foreman](evals/foreman.md) | Foreman eval test cases |
| [evals/lead](evals/lead.md) | Lead eval test cases |
| [evals/spilling](evals/spilling.md) | Tool result spilling eval test cases |
| [evals/skills](evals/skills.md) | Skill suggestion & invocation eval test cases |
| [evals/issues](evals/issues.md) | Issue creation eval test cases |
| [evals/e2e](evals/e2e.md) | End-to-end task battery & overnight loop |

## Notes

### Design decisions

- **Three layers, not two.** Unit + eval leaves a gap: multi-process OTP coordination that doesn't need real LLM calls but can't be tested with a failing mock. ScriptedProvider fills that gap.
- **ScriptedProvider over recorded cassettes.** Cassettes (VCR-style recording) couple tests to a specific model version and are fragile when prompts change. Scripted responses are explicit about what the test expects.
- **No coverage targets.** Coverage percentages incentivize testing trivial code. Named categories of must-test behavior focus effort where it matters.
- **Statistical evals are not unit tests.** An eval that passes 85% of the time is meaningful. A unit test that passes 85% of the time is broken. Keeping them in separate layers with different expectations prevents confusion.

## References

- [evals/README.md](evals/README.md) — eval infrastructure
- [../standards.md](../standards.md) — coding standards, test infrastructure
- [../harness.md](../harness.md) — agent loop
- [../orchestration.md](../orchestration.md) — Foreman/Lead/Runner
- [../providers.md](../providers.md) — provider behaviour
