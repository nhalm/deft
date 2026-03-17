# Holdout Fixture Set

This directory contains holdout fixtures that are **never used during prompt engineering or development**. They are reserved for validation only.

## Purpose

Holdout fixtures validate that prompts generalize beyond the development set. Without a holdout set, prompts can overfit to the eval suite and fail on real usage.

## Guidelines

- **20-30% reserve** — Holdout should contain 20-30% of total fixtures
- **Never used in development** — Do not reference these fixtures when adjusting prompts
- **Mirror main structure** — Subdirectories match `fixtures/` structure
- **Same quality standard** — Holdout fixtures follow the same design principles as development fixtures

## Usage

Holdout tests are excluded from normal eval runs:

```bash
make test.eval              # Excludes holdout (--exclude holdout)
make test.eval.holdout      # Only runs holdout (--only holdout)
```

## Validation

After prompt changes, compare holdout vs development pass rates:

- ✅ Within 10pp: Prompt generalizes well
- ⚠️ More than 10pp gap: Prompt is overfit, needs revision

Tag all holdout tests with `@tag :holdout` in test files.
