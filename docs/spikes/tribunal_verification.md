# Tribunal Version Verification Spike

**Date:** 2026-03-17
**Spec:** evals v0.2
**Status:** ✅ Complete

## Summary

Tribunal v1.3.5 provides all required assertions and evaluation capabilities for the Deft evals infrastructure. No gaps identified. Ready for implementation.

## Tribunal Version

- **Latest version:** `1.3.5` (released 2026-03-05)
- **Recommended dependency:** `{:tribunal, "~> 1.3"}`
- **Repository:** https://github.com/georgeguimaraes/tribunal
- **Documentation:** https://hexdocs.pm/tribunal

## Required Assertions - Verification Results

### Deterministic Assertions (✅ All Available)

| Required | Tribunal Provides | Notes |
|----------|-------------------|-------|
| `assert_contains` | `:contains` | ExUnit macro provided via `use Tribunal.EvalCase` |
| `assert_regex` | `:regex` | Supports pattern matching with capture groups |
| `assert_json` | `:is_json` | Validates and parses JSON |
| `assert_max_tokens` | `:max_tokens` | Approximate token counting (~0.75 words/token) |

### LLM-as-Judge Assertions (✅ All Available)

| Required | Tribunal Provides | Notes |
|----------|-------------------|-------|
| `assert_faithful` | `:faithful` | Requires `context` field in test case |
| `refute_hallucination` | `:hallucination` | Detects claims not supported by context |
| `refute_pii` | `:pii` | Detects direct/indirect identifiers, sensitive data |

### Evaluation Mode (✅ Available)

- ✅ Mix task: `mix tribunal.eval`
- ✅ Threshold support: `--threshold 0.8`
- ✅ Configurable output formats: `--format json`
- ✅ Parallel execution: `--concurrency N`
- ✅ Pass rate reporting with confidence intervals
- ✅ ExUnit integration for test assertions

## Additional Capabilities (Bonus)

Tribunal provides several assertions beyond our minimum requirements:

**Deterministic:**
- `:contains_any`, `:contains_all`, `:not_contains`
- `:starts_with`, `:ends_with`, `:equals`
- `:min_length`, `:max_length`, `:word_count`
- `:is_url`, `:is_email`
- `:levenshtein` (edit distance)
- `:latency_ms`

**LLM-as-Judge:**
- `:relevant` - Query relevance checking
- `:correctness` - Answer correctness vs expected
- `:bias`, `:toxicity`, `:harmful`, `:jailbreak` - Safety checks
- `:refusal` - Detects appropriate refusals
- Custom judges via `Tribunal.Judge` behaviour

**Red Team Testing:**
- Attack generation: encoding, injection, jailbreak attempts
- Useful for safety eval development

## Dependencies

```elixir
# Required
{:tribunal, "~> 1.3"}

# Optional but recommended for LLM-as-judge
{:req_llm, "~> 1.2"}

# Optional for embedding-based similarity
{:alike, "~> 0.1"}
```

## Test Modes

| Mode | Use Case | Command |
|------|----------|---------|
| **Test Mode** | CI gates, safety checks | `mix test --only eval` |
| **Evaluation Mode** | Benchmarking, baseline tracking | `mix tribunal.eval` |

## Gaps and Fallback Plan

**Gaps:** None identified.

**Fallback plan:** Not needed. Tribunal v1.3.5 fully satisfies all requirements from evals spec v0.2 section 1.1.

## Recommendations

1. **Use Tribunal v1.3.5** - Add `{:tribunal, "~> 1.3"}` to mix.exs
2. **Include req_llm** - Required for LLM-as-judge assertions (faithful, hallucination, PII)
3. **Follow ExUnit integration pattern** - Use `use Tribunal.EvalCase` for test mode assertions
4. **Leverage evaluation mode** - Use `mix tribunal.eval` for baseline tracking and regression detection
5. **Explore red team testing** - Consider for safety eval development (Phase 1 bootstrapping)

## Implementation Notes

- Tribunal uses `:atom` notation internally (`:contains`, `:faithful`) but provides `assert_*`/`refute_*` macros via ExUnit integration
- LLM-as-judge assertions require `context` field in test case struct
- Default judge model is `claude-3-5-haiku-latest`, configurable per assertion
- Token counting is approximate (~0.75 words/token) - sufficient for threshold checks
- Evaluation mode supports custom reporters and GitHub Actions integration

## Next Steps

1. Add Tribunal dependencies to mix.exs
2. Create test/eval/ directory structure per evals spec section 1.2
3. Implement judge calibration infrastructure (50 gold-labeled examples)
4. Begin Phase 1 evals (Observer extraction, Reflector compression, issue elicitation)
