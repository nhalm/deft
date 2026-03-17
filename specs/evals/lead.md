# Lead Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [orchestration](../orchestration.md) |

## Test Cases

### 6.1 Task Decomposition

**Input:** Deliverable description + research findings.
**Expected:** 4-8 concrete Runner tasks, dependency-ordered, each with clear done state.

**Pass rate:** 75% over 20 iterations

### 6.2 Steering Quality

**Input:** Runner produced code using bcrypt instead of argon2.
**Expected:** Lead identifies the specific error and provides clear correction. Not just "redo it."

**Pass rate:** 75% over 20 iterations

## Fixtures

- Deliverable descriptions with research findings for decomposition testing
- Runner output with specific errors for steering quality testing
