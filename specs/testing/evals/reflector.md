# Reflector Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [observational-memory](../../observational-memory.md) |

## Test Cases

### 3.1 Compression Target

**Input:** 40k tokens of observation text.
**Expected:** Output ≤ 20k tokens (50% of threshold).

**Pass rate:** 90% over 20 iterations

### 3.2 High-Priority Preservation

**Input:** Observations with 10 🔴 items, 30 🟡 items, 20 unlabeled items.
**Expected:** All 🔴 items survive compression.

**Pass rate:** 95% over 20 iterations for 🔴 survival

### 3.3 Section Structure Preservation

**Input:** Observation text with all 5 standard sections.
**Expected:** Output contains all 5 section headers in canonical order.

**Type:** Hard assertion (run once). If this fails, it's a prompt bug — fix the prompt, don't accept a pass rate.

### 3.4 CORRECTION Marker Survival

**Input:** Observation text containing 3 CORRECTION markers.
**Expected:** All 3 appear in compressed output.

**Type:** Hard assertion (run once). The post-compression check enforces this; the eval verifies the check works.

## Fixtures

- Large observation text (~40k tokens) for compression testing
- Observation sets with mixed priority items (🔴, 🟡, unlabeled)
- Observation text with all 5 standard section headers
- Observation text containing CORRECTION markers
