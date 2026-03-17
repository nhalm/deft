# AI Evals

| | |
|--------|----------------------------------------------|
| Version | 0.2 |
| Status | Ready |
| Last Updated | 2026-03-17 |

## Changelog

### v0.2 (2026-03-17)
- Major expansion: added eval categories for tool result spilling, cache retrieval, skill suggestion and invocation, issue creation, end-to-end task completion, overnight loop safety
- Increased iterations from 10 to 20-30 for statistical significance
- Added holdout fixture set requirement (20-30% unseen during prompt development)
- Added eval result storage with failure examples (per-run JSONL, not just baselines)
- Added LLM-as-judge calibration requirement
- Added bootstrapping strategy (what to eval before the agent exists)
- Added threshold tuning methodology (grid search, not guessing)
- Moved section ordering and CORRECTION survival from statistical pass rates to hard assertions
- Added eval tiers for solo developer (Tier 1: $2/push, Tier 2: $5/major changes, Tier 3: weekly benchmarks)
- Resolved open questions: eval cost budget, multi-model evals

### v0.1 (2026-03-16)
- Initial spec — comprehensive AI eval definitions for all LLM-powered components

## Overview

AI eval tests verify that Deft's LLM-powered components produce correct, useful output — not just that they don't crash. Every component that calls an LLM has eval tests that define what good output looks like and what failure modes to catch.

Evals are the quality gate between "this code compiles and runs" and "this actually works as a coding agent." They are non-negotiable for any LLM-powered feature.

**Scope:**
- Eval test definitions for every LLM-powered component
- Expected outcomes with concrete pass/fail criteria
- Eval infrastructure (Tribunal, fixtures, scoring, result storage)
- Statistical confidence requirements
- Regression tracking with historical trends
- Bootstrapping strategy (what to eval before the full agent exists)
- Threshold tuning methodology
- End-to-end task completion evals
- Overnight loop safety evals

**Out of scope:**
- Unit tests for non-LLM code (see [standards.md](../standards.md))
- The eval framework implementation itself (Tribunal is a dependency)
- Defining specific built-in skills or commands (individual skill specs)

**Dependencies:**
- [standards.md](../standards.md) — testing infrastructure, Tribunal setup, test tags
- [observational-memory.md](../observational-memory.md) — Observer and Reflector behavior
- [harness.md](../harness.md) — agent loop, message format
- [providers.md](../providers.md) — provider behavior
- [orchestration.md](../orchestration.md) — Foreman planning, Lead steering
- [filesystem.md](../filesystem.md) — tool result spilling, site log, cache
- [skills.md](../skills.md) — skill auto-selection
- [issues.md](../issues.md) — interactive issue creation, `deft work`

**Design principles:**
- **Prescriptive, not vague.** Every eval defines exact input, expected output properties, and pass/fail criteria.
- **Statistical where necessary, deterministic where possible.** LLM judgment calls use pass rates over 20-30 iterations. Output format correctness (section ordering, marker survival) uses hard assertions — if the format is wrong 5% of the time, that's a prompt bug to fix, not a threshold to accept.
- **Fixture-driven.** Eval inputs are synthetic fixtures, not recorded conversations. Synthetic fixtures are minimal, focused, and don't carry baggage from prior model runs.
- **Regression-tracked with history.** Pass rates are stored per run with commit SHAs and failure examples. Trends are visible. Regressions are detected statistically, not by arbitrary fixed thresholds.
- **Holdout-protected.** 20-30% of fixtures are reserved as a holdout set, never seen during prompt development. This prevents overfitting prompts to the eval suite.
- **Calibrated judges.** LLM-as-judge prompts are validated against human ratings on 50 examples before being used as automated gates.

**Component eval specs:**
- [observer.md](observer.md) — Observer evals
- [reflector.md](reflector.md) — Reflector evals
- [actor.md](actor.md) — Actor evals
- [foreman.md](foreman.md) — Foreman evals
- [lead.md](lead.md) — Lead evals
- [spilling.md](spilling.md) — Tool result spilling evals
- [skills.md](skills.md) — Skill suggestion & invocation evals
- [issues.md](issues.md) — Issue creation evals
- [e2e.md](e2e.md) — End-to-end task battery + overnight loop

## Specification

### 1.1 Framework

All evals use **Tribunal** (`{:tribunal, "~> x.y"}`). Verify the current Tribunal version on hex.pm before implementation. The version constraint should match what is available. If Tribunal does not provide the required assertions, evaluate alternatives or plan custom implementation. Tribunal provides:
- **Deterministic assertions:** `assert_contains`, `assert_regex`, `assert_json`, `assert_max_tokens`
- **LLM-as-judge assertions:** `assert_faithful`, `refute_hallucination`, `refute_pii`
- **Evaluation mode:** Run N iterations, pass if threshold met

### 1.2 Test Organization

```
test/eval/
├── observer/
│   ├── extraction_test.exs
│   ├── priority_test.exs
│   ├── section_routing_test.exs
│   ├── anti_hallucination_test.exs
│   └── dedup_test.exs
├── reflector/
│   ├── compression_test.exs
│   └── preservation_test.exs
├── actor/
│   ├── observation_usage_test.exs
│   ├── continuation_test.exs
│   └── tool_selection_test.exs
├── foreman/
│   ├── decomposition_test.exs
│   ├── dependency_test.exs
│   ├── contract_test.exs
│   ├── constraint_propagation_test.exs
│   └── verification_accuracy_test.exs
├── lead/
│   ├── task_planning_test.exs
│   └── steering_test.exs
├── spilling/
│   ├── summary_quality_test.exs
│   ├── cache_retrieval_test.exs
│   └── threshold_calibration_test.exs
├── skills/
│   ├── suggestion_test.exs
│   └── invocation_fidelity_test.exs
├── issues/
│   ├── elicitation_quality_test.exs
│   └── agent_created_quality_test.exs
├── e2e/
│   ├── single_task_test.exs
│   ├── multi_agent_test.exs
│   ├── loop_safety_test.exs
│   └── verification_circuit_breaker_test.exs
├── fixtures/
│   ├── coding_conversations/
│   ├── codebase_snapshots/
│   │   └── phoenix-minimal/
│   ├── observation_sets/
│   ├── tool_results/
│   ├── issue_transcripts/
│   └── holdout/                    # 20-30% of fixtures, never used in prompt development
├── results/
│   └── <run_id>.jsonl              # Per-run results with failure examples
└── support/
    ├── eval_helpers.ex
    ├── scoring.ex
    └── judge_calibration.ex
```

### 1.3 Fixture Design

Eval inputs are **synthetic fixtures**, not recorded conversations. Each fixture is a JSON file:

```json
{
  "id": "observer-explicit-tech-choice-001",
  "spec_version": "0.1",
  "description": "User explicitly states a technology choice",
  "tags": ["observer", "extraction", "red-priority"],
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "We use PostgreSQL for our database."}]}
  ],
  "context": {},
  "assertions": [
    {"type": "contains", "value": "PostgreSQL"},
    {"type": "section", "section": "User Preferences", "contains": "PostgreSQL"}
  ]
}
```

Fixture design principles:
- **Minimal surface area.** Fewest messages needed to exercise the behavior. 3-message fixtures over 50-message ones.
- **Anti-hallucination fixtures include tempting content.** Don't just omit the thing; actively include text that could tempt hallucination.
- **Version fixtures with the spec.** Each fixture has a `spec_version` field. When the spec changes, stale fixtures are flagged.
- **Codebase snapshots for Foreman/Lead evals.** Small but realistic — a minimal Phoenix app with routes, schemas, and mix.exs. Checked into `test/eval/fixtures/codebase_snapshots/`.

### 1.4 Holdout Set

20-30% of fixtures are reserved in `fixtures/holdout/` and are **never used during prompt engineering**. They are only run to validate that prompts generalize beyond the development fixtures. If holdout pass rate doesn't match development pass rate, the prompt is overfit.

Holdout fixtures are tagged `@tag :holdout` in tests. The `make test.eval` target excludes holdout tests. Only `make test.eval.holdout` runs them. CI runs holdout tests weekly alongside Tier 3 benchmarks.

### 1.5 Iterations and Pass Rates

| Category | Iterations | Threshold | Type |
|----------|-----------|-----------|------|
| Safety (hallucination, PII) | 20 | 95% | Statistical |
| Extraction accuracy | 20 | 85% | Statistical |
| Compression quality | 20 | 80% | Statistical |
| Decomposition quality | 20 | 75% | Statistical |
| Steering quality | 20 | 75% | Statistical |
| Skill auto-selection | 20 | 80% | Statistical |
| Issue elicitation quality | 20 | 80% | Statistical |
| Cache retrieval behavior | 20 | 85% | Statistical |
| Section ordering | 1 iteration, hard assertion (not statistical) | 100% | Hard assertion |
| CORRECTION marker survival | 1 iteration, hard assertion (not statistical) | 100% | Hard assertion |

Hard assertions are run once per eval — if the format is wrong, that's a prompt bug to fix. Statistical evals run 20+ iterations to get meaningful confidence intervals.

**Report format:** Raw rate + confidence interval, not just pass/fail:
```
observer.extraction: 17/20 (85%) [CI: 62%-97%] PASS
foreman.decomposition: 12/20 (60%) [CI: 36%-81%] WARN ← investigate
```

### 1.6 LLM-as-Judge Calibration

Before deploying any LLM-as-judge assertion as an automated gate:
1. Collect 50 examples with human-graded gold labels
2. Run the judge prompt against all 50
3. Measure precision and recall against the gold standard
4. Only deploy if precision > 85% and recall > 80%
5. Store the calibration set in `test/eval/support/judge_calibration/`
6. Re-run calibration when changing judge model or prompt

### 1.7 Eval Tags

Every eval test is tagged for selective execution:

```elixir
@tag :eval           # separates from unit tests
@tag :expensive      # multiple LLM calls — exclude from quick pre-commit runs
@tag :integration    # requires running codebase, not just fixtures
@tag :e2e            # full end-to-end, requires working agent
```

### 12. Eval Result Storage

#### 12.1 Per-Run Results

Each eval run produces a JSONL file at `test/eval/results/<run_id>.jsonl`:

```json
{
  "run_id": "2026-03-16-abc123",
  "commit": "def456",
  "timestamp": "2026-03-16T14:00:00Z",
  "model": "claude-sonnet-4-6",
  "category": "observer.extraction",
  "pass_rate": 0.85,
  "iterations": 20,
  "cost_usd": 0.42,
  "failures": [
    {"fixture": "observer-tech-choice-003", "output": "...", "reason": "Missing PostgreSQL in extraction"}
  ]
}
```

Failure examples are critical — when pass rate drops, you need to see *which* inputs failed.

Results directory is `.gitignore`d. Keep the last 30 runs on disk. Use `mix eval.export` to archive results to a separate tracking file if long-term history is needed.

#### 12.2 Baselines with History

`test/eval/baselines.json` stores historical tracking, not just last-known values:

```json
{
  "observer.extraction": {
    "baseline": 0.88,
    "soft_floor": 0.78,
    "history": [
      {"run_id": "ci-2026-03-10-abc", "rate": 0.85, "n": 20, "commit": "a1b2c3d"},
      {"run_id": "ci-2026-03-12-def", "rate": 0.90, "n": 20, "commit": "e4f5g6h"}
    ]
  }
}
```

The `soft_floor` is baseline minus 10 percentage points. Dropping below the soft floor requires documented justification, not just a baseline update.

#### 12.3 Regression Detection

Use a proportion z-test comparing the current run against the historical distribution, not a fixed 10-point threshold:

```elixir
def significant_regression?(current_rate, current_n, historical_rates) do
  # Guard: no regression can be detected without history
  if historical_rates == [] do
    false
  else
    pooled = Enum.mean(historical_rates)

    # Guard: pooled at boundaries makes z-test degenerate.
    # Apply Laplace smoothing or return false.
    cond do
      pooled == 0.0 or pooled == 1.0 ->
        # Laplace smoothing: shift pooled slightly away from boundary
        n = length(historical_rates)
        pooled = (pooled * n + 0.5) / (n + 1)
        se = :math.sqrt(pooled * (1 - pooled) / current_n)
        z = (current_rate - pooled) / se
        z < -1.645

      true ->
        se = :math.sqrt(pooled * (1 - pooled) / current_n)
        z = (current_rate - pooled) / se
        z < -1.645  # p < 0.05 one-tailed
    end
  end
end
```

Separate infrastructure failures (same error in 8/10 failures = deterministic bug) from model quality regressions (varied errors = actual quality change).

#### 12.4 Eval Diffing

`mix eval.compare <run_a> <run_b>` shows:
- Categories that changed and by how much
- Categories that dropped below soft floor
- Failure examples side-by-side

### 13. Eval Execution

#### 13.1 Tiered Execution

| Tier | What | Cost | When |
|------|------|------|------|
| Tier 1 | Component evals (Observer, Reflector, Actor) | ~$2 | Every push |
| Tier 2 | End-to-end harness (3 core tasks) | ~$5 | Before shipping major Foreman/orchestration changes |
| Tier 3 | Full benchmark (8 tasks) + overnight loop | ~$15 | Weekly |
| Calibration | Threshold grid search | ~$20-30 | During threshold tuning only |

```bash
make test.eval              # Tier 1: component evals
make test.eval.e2e          # Tier 2: end-to-end harness
make test.eval.benchmark    # Tier 3: full benchmark suite
make test.eval.calibrate    # Calibration: threshold grid search
```

#### 13.2 CI Integration

- Tier 1 runs on every push as a **soft gate** (warn on regression, fail only on safety evals)
- Tier 2 runs on merge to main
- Tier 3 runs on a weekly schedule
- Safety evals (hallucination, PII) that drop below 90% **hard fail** the build

#### 13.3 Multi-Model Strategy

Deft ships with configurable models. Evals run against the default model (Sonnet). When bumping the pinned model version, re-run the full Tier 1+2 suite against the new model and update baselines if pass rates change. Cross-model evals (Sonnet vs Haiku) are deferred until there's a user base to justify the cost.

### 14. Bootstrapping Strategy

What to build and eval before the full agent exists, in order:

| Phase | What exists | What to eval | How |
|-------|-------------|-------------|-----|
| 1 | Nothing | Observer extraction, Reflector compression, issue elicitation | Direct LLM calls — no agent loop needed. `Observer.extract(messages, observations)` is a standalone function. |
| 2 | Tools + Store | Tool result spilling format, summary quality, cache reference parsing | Deterministic format checks + LLM-as-judge on summary quality |
| 3 | Agent loop | Actor evals, skill invocation, tool selection | Mox-based fake provider for deterministic state machine tests, real LLM for behavior evals |
| 4 | Orchestration | Foreman decomposition, Lead steering, constraint propagation, verification circuit breaker | Full integration against codebase snapshots |
| 5 | Everything | End-to-end tasks, overnight loop, single vs multi-agent comparison | Synthetic repos with issues |

**Phase 1 is available immediately** and should be the first eval work done. The issue elicitation eval is the highest-value Phase 1 eval because its output quality directly determines `deft work` quality.

**Note:** The evals work items in specd_work_list.md must be updated to include: spilling evals, skill suggestion evals, issue creation evals, e2e task battery, overnight loop eval, eval result storage infrastructure, judge calibration setup, and holdout fixture creation.

### 15. Eval Maintenance

- **New features require new evals.** Any PR that adds or modifies an LLM-powered component must include eval tests for the new behavior.
- **Fixture updates.** When the message format or observation format changes, update fixtures. Run a fixture validation check that verifies each fixture's `spec_version` matches the current spec.
- **Baseline updates.** After prompt improvements, update baselines to the new (higher) pass rates. Baselines only go up. The soft floor moves with the baseline.
- **Judge recalibration.** When changing the judge model or prompt, re-run the calibration set (50 gold-labeled examples) and verify precision/recall.
- **Holdout validation.** After prompt changes, run the holdout set and compare pass rates. If holdout is >10pp below development set, the prompt is overfit.

## Notes

### Design decisions

- **Tribunal over custom eval framework.** Tribunal is the only Elixir-native LLM eval library. Building custom would be significant effort for no benefit.
- **Synthetic fixtures over recorded conversations.** Recorded conversations carry baggage (irrelevant content, PII, model-version coupling). Synthetic fixtures are minimal, focused, and make failure analysis clearer.
- **Soft gate in CI for statistical evals, hard gate for safety and format.** LLM judgment varies — soft gates prevent flaky CI. Output format must be correct every time — those are prompt bugs, not variance.
- **20-30 iterations, not 10.** 10 samples at 85% true rate gives 95% CI of 55%-98% — you can't distinguish good from bad. At 20+ samples, failures are meaningful.
- **Holdout set.** Standard ML practice. Without it, prompts overfit to the eval suite and fail on real usage. 20-30% reserve is the standard split.
- **Statistical regression detection.** A proportion z-test is more principled than "did it drop 10 points?" and automatically adjusts for historical variance.
- **Verification circuit breaker is the highest-priority eval.** If the Foreman marks broken work as done, every other eval result becomes suspect. This eval validates the safety net.
- **Per-run failure examples.** Without them, a pass rate drop is a mystery. With them, you can immediately see what broke and whether it's a prompt issue, a fixture issue, or a real regression.

## References

- [Tribunal](https://hex.pm/packages/tribunal) — Elixir LLM evaluation framework
- [standards.md](../standards.md) — testing infrastructure
- [observational-memory.md](../observational-memory.md) — Observer/Reflector behavior
- [orchestration.md](../orchestration.md) — Foreman/Lead behavior
- [filesystem.md](../filesystem.md) — tool result spilling, cache
- [skills.md](../skills.md) — skill auto-selection
- [issues.md](../issues.md) — interactive issue creation
