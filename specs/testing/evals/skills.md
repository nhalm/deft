# Skill Suggestion & Invocation Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [skills](../../skills.md) |

## Test Cases

### 8.1 Skill Usage

**Input:** Conversation where a specific skill would be helpful (e.g., user is about to commit code, `/commit` skill is available).
**Expected:** Agent suggests the appropriate skill in its response.

| Scenario | Available skills | Expected suggestion |
|----------|-----------------|-------------------|
| User says "I think this is ready to commit" | `/commit`, `/review` | `/commit` or `/review` |
| User asks about deployment readiness | `/deploy-check` | `/deploy-check` |
| User discusses code quality | `/review` | `/review` |
| User does normal coding work | `/commit`, `/review` | No suggestion (don't spam) |

LLM-as-judge: "Does the response suggest a relevant available skill? Is the suggestion appropriate for the conversational context?"

**Pass rate:** 80% over 20 iterations

### 8.2 Invocation Fidelity

**Input:** Skill definition injected into context. The skill specifies multi-step instructions.
**Expected:** Agent follows the steps in order.

**Pass rate:** 85% over 20 iterations

## Fixtures

- Conversation fixtures with skill-relevant contexts (committing, reviewing, deploying)
- Skill definitions with multi-step instructions for fidelity testing
- Normal coding conversations where no skill suggestion is appropriate
