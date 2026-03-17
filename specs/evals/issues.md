# Issue Creation Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [issues](../issues.md) |

## Test Cases

### 9.1 Elicitation Quality

**Input:** A simulated user conversation for issue creation (title + terse user responses).
**Expected:** The resulting structured issue JSON has:
- `acceptance_criteria` that are specific and testable (not "it should work correctly")
- `constraints` that are restrictions on how, not goals
- `context` that explains motivation, not just restates the title
- All three fields non-empty

LLM-as-judge: "Is each acceptance criterion testable with code or manual verification? Yes/No."

**Pass rate:** 80% over 20 iterations

### 9.2 Issue Quality → Plan Quality Diagnostic

**Input:** Same task given to the Foreman twice — once with a well-structured issue (good AC, constraints), once with a bare title (`--quick` mode).
**Expected:** The plan from the well-structured issue has more specific task instructions and concrete verification targets.

LLM-as-judge comparing the two plans. If interactive issues don't produce better downstream outcomes than `--quick` issues, the creation session is friction without payoff.

This is a diagnostic eval, not a gate. Run periodically to validate the creation session is delivering value.

### 9.3 Agent-Created Issue Quality

**Input:** Agent discovers out-of-scope work during a session and creates an issue autonomously.
**Expected:** The created issue has enough context to be actionable — not just a title. Source is `:agent`, priority is 3.

**Pass rate:** 75% over 20 iterations

## Fixtures

- Simulated user conversations for issue creation (title + terse responses)
- Well-structured vs bare-title issue pairs for diagnostic comparison
- Agent session contexts where out-of-scope work is discovered
