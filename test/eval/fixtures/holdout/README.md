# Holdout Fixture Set

This directory contains **holdout fixtures** — the 20-30% of eval fixtures that are **never used during prompt engineering**.

## Purpose

Holdout fixtures validate that prompts generalize beyond the development fixtures. If the holdout pass rate doesn't match the development pass rate, the prompt is overfit to the eval suite.

## Usage

### Adding Holdout Fixtures

1. Place fixture JSON files in this directory using the same format as development fixtures
2. Tag tests that use these fixtures with `@tag :holdout` or `@moduletag :holdout`
3. Holdout fixtures should represent ~20-30% of the total fixture set for each eval category

### Running Holdout Tests

```bash
# Development evals (excludes holdout)
make test.eval

# Holdout validation only
make test.eval.holdout
```

### When to Run

- **Weekly:** As part of CI's weekly Tier 3 benchmark suite
- **After prompt changes:** Validate that improvements generalize
- **Never during prompt development:** These fixtures must remain unseen until validation

## Example Holdout Test

```elixir
defmodule Deft.Eval.Observer.ExtractionHoldoutTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  @moduletag :eval
  @moduletag :holdout  # ← marks this as a holdout test
  @moduletag :expensive

  test "holdout: tech choice extraction variant" do
    # Test implementation using fixtures from this directory
  end
end
```

## Guidelines

- **Never peek:** Do not inspect holdout fixtures when tuning prompts
- **Version sync:** Keep holdout fixtures at the same spec_version as development fixtures
- **Representative sampling:** Holdout fixtures should cover the same distribution of cases as development fixtures
- **Detection threshold:** If holdout pass rate is >10pp below development, investigate overfitting

## References

See [specs/evals/README.md](../../../specs/evals/README.md) section 1.4 for the full specification.
