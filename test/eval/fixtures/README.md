# Eval Fixtures

This directory contains synthetic fixture files for eval tests. Each fixture is a JSON file with:

- `id`: Unique identifier
- `spec_version`: Version of the spec this fixture tests (e.g., "0.1")
- `description`: Human-readable description
- `tags`: Array of tags for categorization
- `messages`: Array of messages in the format expected by the component
- `context`: Additional context for the test
- `assertions`: Array of assertions to verify against the output

## Directory Structure

- `observer/` — Observer extraction tests
- `reflector/` — Reflector compression tests
- `actor/` — Actor behavior tests
- `foreman/` — Foreman planning and decomposition tests
- `lead/` — Lead task planning and steering tests
- `spilling/` — Tool result spilling tests
- `skills/` — Skill suggestion and invocation tests
- `issues/` — Issue creation tests
- `e2e/` — End-to-end integration tests
- `holdout/` — Holdout fixtures (20-30% reserve, see below)

## Fixture Design Principles

1. **Minimal surface area** — Fewest messages needed to exercise the behavior
2. **Anti-hallucination fixtures include tempting content** — Don't just omit the thing; actively include text that could tempt hallucination
3. **Version fixtures with the spec** — Each fixture has a `spec_version` field that matches the spec version it tests

## Holdout Set

The `holdout/` subdirectory contains 20-30% of all fixtures reserved for validation. These fixtures are:

- Never used during prompt engineering or development
- Only run via `make test.eval.holdout`
- Used to validate that prompts generalize beyond the development fixtures
- Tagged with `@tag :holdout` in test files

If holdout pass rate doesn't match development pass rate within 10 percentage points, the prompt is overfit and needs revision.

## Usage

Run fixture validation to check for stale fixtures:

```bash
make test.eval.validate_fixtures
```

This verifies that each fixture's `spec_version` matches the current spec version.
