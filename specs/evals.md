# AI Evals

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Draft |
| Last Updated | 2026-03-16 |

## Changelog

### v0.1 (2026-03-16)
- Initial spec — comprehensive AI eval definitions for all LLM-powered components

## Overview

AI eval tests verify that Deft's LLM-powered components produce correct, useful output — not just that they don't crash. Every component that calls an LLM has eval tests that define what good output looks like and what failure modes to catch.

Evals are the quality gate between "this code compiles and runs" and "this actually works as a coding agent." They are non-negotiable for any LLM-powered feature.

**Scope:**
- Eval test definitions for every LLM-powered component
- Expected outcomes with concrete pass/fail criteria
- Eval infrastructure (Tribunal, fixtures, scoring)
- Statistical confidence requirements
- Regression tracking

**Out of scope:**
- Unit tests for non-LLM code (see [standards.md](standards.md))
- The eval framework implementation itself (Tribunal is a dependency)

**Dependencies:**
- [standards.md](standards.md) — testing infrastructure, Tribunal setup, test tags
- [observational-memory.md](observational-memory.md) — Observer and Reflector behavior
- [harness.md](harness.md) — agent loop, message format
- [providers.md](providers.md) — provider behavior
- [orchestration.md](orchestration.md) — Foreman planning, Lead steering

**Design principles:**
- **Prescriptive, not vague.** Every eval defines exact input, expected output properties, and pass/fail criteria. "Test that the Observer works" is not an eval. "Given a conversation where the user states they use PostgreSQL, the Observer must extract an observation containing 'PostgreSQL' with 🔴 priority" is an eval.
- **Statistical, not deterministic.** LLM outputs are non-deterministic. Evals use Tribunal's evaluation mode with confidence thresholds. A single failure is not a bug; a consistent drop in pass rate is.
- **Fixture-driven.** Eval inputs are recorded conversation fixtures, not live conversations. This ensures reproducibility.
- **Regression-tracked.** Pass rates are recorded over time. A new code change that drops pass rates below the threshold blocks the change.

## Specification

### 1. Eval Infrastructure

#### 1.1 Framework

All evals use **Tribunal** (`{:tribunal, "~> 1.3"}`). Tribunal provides:
- **Deterministic assertions:** `assert_contains`, `assert_regex`, `assert_json`, `assert_max_tokens`
- **LLM-as-judge assertions:** `assert_faithful`, `refute_hallucination`, `refute_pii`
- **Evaluation mode:** Run N iterations, pass if threshold met (e.g., 80% pass rate)

#### 1.2 Test Organization

```
test/eval/
├── observer/
│   ├── extraction_test.exs        # Observer extracts correct facts
│   ├── priority_test.exs          # Observer assigns correct priorities
│   ├── section_routing_test.exs   # Facts routed to correct sections
│   ├── anti_hallucination_test.exs # Observer doesn't fabricate
│   └── dedup_test.exs             # Observer doesn't duplicate existing observations
├── reflector/
│   ├── compression_test.exs       # Reflector hits target size
│   ├── preservation_test.exs      # High-priority items survive compression
│   ├── section_structure_test.exs # Section ordering preserved
│   └── correction_survival_test.exs # CORRECTION markers survive
├── actor/
│   ├── observation_usage_test.exs # Actor references observations correctly
│   ├── continuation_test.exs      # Actor continues naturally after message trimming
│   └── tool_selection_test.exs    # Actor picks appropriate tools
├── foreman/
│   ├── decomposition_test.exs     # Foreman produces valid work plans
│   ├── dependency_test.exs        # Dependency DAG is correct
│   └── contract_test.exs          # Interface contracts are specific enough
├── lead/
│   ├── task_planning_test.exs     # Lead decomposes deliverable into tasks
│   └── steering_test.exs          # Lead corrects Runner mistakes
├── fixtures/
│   ├── coding_conversations/      # Recorded conversations for Observer/Reflector tests
│   ├── codebase_snapshots/        # Small codebases for Foreman/Lead tests
│   └── observation_sets/          # Pre-built observation texts for Reflector/Actor tests
└── support/
    ├── eval_helpers.ex            # Common setup, fixture loading
    └── scoring.ex                 # Pass rate tracking, regression detection
```

#### 1.3 Fixtures

Eval inputs are **recorded fixtures**, not live conversations. Each fixture is a JSON file containing:
- `messages` — conversation messages in `Deft.Message` format
- `context` — any additional context (existing observations, project instructions)
- `expected` — expected output properties (used in assertions)

Fixtures represent real coding scenarios:
- Short bug-fix conversation (5-10 exchanges)
- Long feature-building session (50+ exchanges)
- Multi-topic session (user pivots between tasks)
- Sessions with errors, corrections, and abandoned approaches
- Sessions with heavy tool usage (many file reads, bash commands)

#### 1.4 Pass Rate Thresholds

| Category | Threshold | Meaning |
|----------|-----------|---------|
| Safety evals (hallucination, PII) | 95% | Near-zero tolerance for fabrication |
| Extraction accuracy | 85% | Observer should capture most facts |
| Compression quality | 80% | Reflector should preserve most important info |
| Decomposition quality | 75% | Foreman plans are reasonable most of the time |
| Steering quality | 75% | Lead corrections are helpful most of the time |

Evals run in Tribunal evaluation mode with 10 iterations each. Pass rate = (passing iterations / total iterations).

### 2. Observer Evals

#### 2.1 Fact Extraction

**Input:** Conversation fixture where the user states explicit facts.

| Test case | Input (user says) | Must contain | Priority |
|-----------|-------------------|-------------|----------|
| Explicit tech choice | "We use PostgreSQL for our database" | "PostgreSQL" | 🔴 |
| Preference statement | "I prefer spaces over tabs" | "spaces" AND "prefer" | 🔴 |
| File read | [Tool result: contents of src/auth.ex] | File path "src/auth.ex" | 🟡 |
| File modification | [Tool call: edit src/auth.ex] | "Modified" AND "src/auth.ex" | 🟡 |
| Error encountered | [Bash output: CompileError in line 42] | Error message verbatim (or close) | 🟡 |
| Command run | [Bash: mix test → 12 tests, 2 failures] | "mix test" AND "2 failures" | 🟡 |
| Architectural decision | "Let's use gen_statem for the agent loop because it has explicit states" | "gen_statem" AND rationale | 🟡 |
| Dependency added | "Add jason ~> 1.4 to the deps" | "jason" AND version | 🟡 |
| Deferred work | "We still need to handle the error case later" | "error case" AND deferred/TODO | 🟡 |

**Assertions:**
```elixir
Tribunal.assert_contains(observations, expected_content)
Tribunal.assert_contains(observations, expected_priority_emoji)
```

**Pass rate:** 85%

#### 2.2 Section Routing

**Input:** Conversation with mixed content types.

| Fact type | Expected section |
|-----------|-----------------|
| User preference | `## User Preferences` |
| File read/modify | `## Files & Architecture` |
| Implementation decision | `## Decisions` |
| Current task description | `## Current State` |
| General conversation event | `## Session History` |

**Assertions:**
```elixir
# Parse sections from output, verify each fact is in the right section
assert_in_section(observations, "PostgreSQL", "User Preferences")
assert_in_section(observations, "src/auth.ex", "Files & Architecture")
```

**Pass rate:** 85%

#### 2.3 Anti-Hallucination

**Input:** Conversation fixture where the user asks hypothetical questions or discusses topics without committing.

| Test case | User says | Must NOT be extracted as fact |
|-----------|-----------|------------------------------|
| Hypothetical | "What if we used Redis?" | "User's database is Redis" or "User chose Redis" |
| Exploring options | "Should we use bcrypt or argon2?" | "User chose bcrypt" or "User chose argon2" |
| Reading about something | [Reads a file about MongoDB] | "User uses MongoDB" |
| Discussing alternatives | "One option would be to use WebSockets" | "User will use WebSockets" |

**Assertions:**
```elixir
Tribunal.refute_hallucination(observations, context: messages)
# Custom: verify no "User chose/uses/decided" for non-committed topics
refute_committed_language(observations, "Redis")
```

**Pass rate:** 95%

#### 2.4 Deduplication

**Input:** Existing observations + new messages that repeat already-observed facts.

**Expected:** New extraction does NOT re-extract facts already present in the existing observations context (8k budget).

**Assertions:**
```elixir
# Count occurrences of a specific fact in combined output
assert count_occurrences(merged_observations, "PostgreSQL") <= 1
```

**Pass rate:** 80%

#### 2.5 Read vs Modified Tracking

**Input:** Conversation where the agent reads a file, then later modifies it.

**Expected:** `## Files & Architecture` section distinguishes:
- "Read `src/auth.ex` — contains JWT verification with verify_token/1"
- "Modified `src/auth.ex` — added refresh_token/1 function"

Not just: "src/auth.ex" twice.

**Pass rate:** 80%

### 3. Reflector Evals

#### 3.1 Compression Target

**Input:** 40k tokens of observation text.

**Expected:** Output is within 50% of reflection threshold (≤ 20k tokens).

**Assertions:**
```elixir
assert Deft.OM.Tokens.estimate(compressed) <= 20_000
```

**Pass rate:** 90% (with escalating levels, this should almost always hit target)

#### 3.2 High-Priority Preservation

**Input:** Observation text with 10 🔴 items, 30 🟡 items, 20 🟢 items.

**Expected:** All 🔴 items survive compression. Most 🟡 items survive (at level 0-1). 🟢 items may be dropped.

**Assertions:**
```elixir
for red_item <- red_items do
  Tribunal.assert_contains(compressed, red_item.key_text)
end
```

**Pass rate:** 95% for 🔴 survival

#### 3.3 Section Structure Preservation

**Input:** Observation text with all 5 standard sections.

**Expected:** Output contains all 5 section headers in canonical order: Current State, User Preferences, Files & Architecture, Decisions, Session History.

**Assertions:**
```elixir
sections = parse_section_headers(compressed)
assert sections == ["Current State", "User Preferences", "Files & Architecture", "Decisions", "Session History"]
```

**Pass rate:** 95%

#### 3.4 CORRECTION Marker Survival

**Input:** Observation text containing 3 CORRECTION markers.

**Expected:** All 3 CORRECTION markers appear in the compressed output.

**Assertions:**
```elixir
input_corrections = extract_corrections(input)
output_corrections = extract_corrections(compressed)
assert MapSet.subset?(MapSet.new(input_corrections), MapSet.new(output_corrections))
```

**Pass rate:** 100% (post-compression check enforces this, so the eval verifies the check works)

### 4. Actor Evals

#### 4.1 Observation Usage

**Input:** Agent context with observations containing "User prefers argon2 for password hashing" + a prompt "implement the login endpoint."

**Expected:** The Actor's response references argon2, not bcrypt or another algorithm.

**Assertions:**
```elixir
Tribunal.assert_contains(response, "argon2")
Tribunal.refute_contains(response, "bcrypt")
```

**Pass rate:** 85%

#### 4.2 Continuation After Trimming

**Input:** Agent context with observations + continuation hint + 3 tail messages, simulating a mid-conversation state after message trimming.

**Expected:** The Actor continues naturally. Does NOT greet the user. Does NOT say "how can I help you today." References the current task from the continuation hint.

**Assertions:**
```elixir
Tribunal.refute_contains(response, "How can I help")
Tribunal.refute_contains(response, "Hello")
Tribunal.assert_contains(response, current_task_keyword)
```

**Pass rate:** 90%

#### 4.3 Tool Selection

**Input:** Various prompts with a coding agent system prompt and tool definitions.

| Prompt | Expected tool | Must NOT use |
|--------|--------------|-------------|
| "Read src/auth.ex" | `read` | `bash` (don't `cat`) |
| "Find all test files" | `find` | `bash` (don't `find` via shell) |
| "Search for 'defmodule Auth'" | `grep` | `bash` (don't `grep` via shell) |
| "Run the tests" | `bash` with `mix test` | — |
| "Change foo to bar in config.exs" | `edit` | `bash` (don't `sed`) |

**Assertions:**
```elixir
assert first_tool_call(response).name == expected_tool
```

**Pass rate:** 85%

### 5. Foreman Evals

#### 5.1 Work Decomposition

**Input:** Codebase snapshot + prompt "Add authentication with JWT to this Phoenix app."

**Expected:**
- Produces 1-3 deliverables (not 5+)
- Each deliverable has a clear description
- Dependency DAG is valid (no circular deps)
- Interface contracts are specific (not just "the API")

**Assertions:**
```elixir
plan = parse_plan(response)
assert length(plan.deliverables) in 1..3
assert valid_dag?(plan.dependencies)
for contract <- plan.contracts do
  # Contracts must mention specific endpoints, data shapes, or function signatures
  Tribunal.assert_regex(contract.content, ~r/(POST|GET|PUT|DELETE)\s+\/|%\{|def\s+\w+/)
end
```

**Pass rate:** 75%

#### 5.2 Single-Agent Detection

**Input:** Simple prompts that should NOT trigger orchestration.

| Prompt | Expected |
|--------|----------|
| "Fix the typo in line 42 of auth.ex" | Single-agent mode |
| "Add a comment to this function" | Single-agent mode |
| "What does this module do?" | Single-agent mode |
| "Build a complete auth system with frontend and backend" | Orchestrated mode |
| "Refactor the billing module and add Stripe integration" | Orchestrated mode |

**Pass rate:** 80%

### 6. Lead Evals

#### 6.1 Task Decomposition

**Input:** Deliverable description "Build backend auth: user model, JWT, middleware, endpoints, tests" + research findings.

**Expected:**
- Produces 4-8 concrete Runner tasks
- Tasks are ordered by dependency
- Each task has a clear "done" state
- First task is foundational (schema/model), not a dependent task (endpoints)

**Pass rate:** 75%

#### 6.2 Steering Quality

**Input:** A Runner produced code that uses bcrypt instead of argon2 (the Lead's context says argon2).

**Expected:** The Lead's corrective instructions:
- Identify the specific error ("used bcrypt, should be argon2")
- Provide the correction clearly
- Do NOT just say "redo it"

**Assertions:**
```elixir
Tribunal.assert_contains(steering, "argon2")
Tribunal.assert_contains(steering, "bcrypt")  # acknowledges the error
Tribunal.refute_regex(steering, ~r/^(redo|try again|fix it)$/i)  # not vague
```

**Pass rate:** 75%

### 7. Eval Execution

#### 7.1 Local

```bash
make test.eval                    # Run all evals
mix test test/eval/observer/ --only eval  # Run Observer evals only
```

Requires `ANTHROPIC_API_KEY` in environment. Each eval run costs approximately $0.50-2.00 depending on which components are tested.

#### 7.2 CI

Evals run in CI on every push but use a **soft gate**:
- Pass rates are recorded per eval category
- If any category drops below its threshold compared to the last recorded baseline, the CI job warns but does NOT fail the build
- If a safety eval (hallucination, PII) drops below 90%, the CI job FAILS
- Pass rate history is stored in `test/eval/baselines.json`

#### 7.3 Regression Detection

`test/eval/baselines.json` stores the last known pass rate per eval category:
```json
{
  "observer.extraction": 0.88,
  "observer.anti_hallucination": 0.97,
  "reflector.compression": 0.92,
  "actor.observation_usage": 0.86,
  "foreman.decomposition": 0.78
}
```

After each eval run, compare current rates to baselines. If any category drops by more than 10 percentage points, flag for investigation.

### 8. Eval Maintenance

- **New features require new evals.** Any PR that adds or modifies an LLM-powered component must include eval tests for the new behavior.
- **Fixture updates.** When the message format or observation format changes, update fixtures. Fixtures are versioned with the spec version.
- **Baseline updates.** After prompt engineering improvements, update baselines to the new (higher) pass rates. Baselines only go up, never down.

## Notes

### Design decisions

- **Tribunal over custom eval framework.** Tribunal is the only Elixir-native LLM eval library. It provides both deterministic and LLM-as-judge assertions, plus evaluation mode for statistical confidence. Building custom would be significant effort for no benefit.
- **Fixtures over live conversations.** Live conversations introduce network latency, cost, and non-reproducibility. Fixtures ensure the same input produces comparable output across runs. The LLM output is still non-deterministic, but the input is fixed.
- **Soft gate in CI.** LLM outputs are inherently non-deterministic. A hard pass/fail gate on eval tests would create flaky CI. The soft gate (warn on regression, fail only on safety) balances quality with practicality.

### Open questions

- **Eval cost budget.** Running all evals costs $0.50-2.00. On every push? On merge to main only? Need to balance cost with coverage.
- **Multi-model evals.** Should evals run against multiple models (Sonnet, Haiku) to verify behavior across the model range? Adds cost but catches model-specific issues.

## References

- [Tribunal](https://hex.pm/packages/tribunal) — Elixir LLM evaluation framework
- [standards.md](standards.md) — testing infrastructure
- [observational-memory.md](observational-memory.md) — Observer/Reflector behavior
- [orchestration.md](orchestration.md) — Foreman/Lead behavior
