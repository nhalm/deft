# Tool Result Spilling Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [filesystem](../../filesystem.md) |

## Test Cases

### 7.1 Summary Quality

**Input:** Tool results at different sizes (500, 2k, 5k, 15k tokens) from grep, read, ls tools.
**Expected:** Summaries mention total count, key structural info, and include a parseable `cache://<key>` reference.

Deterministic checks:
- `cache://` reference present and parseable
- Summary mentions result count/size
- Summary is below the threshold

LLM-as-judge: "Does this summary give the agent enough information to decide whether it needs the full result?"

**Pass rate:** 85% over 20 iterations for quality; 100% hard assertion for format

### 7.2 Cache Retrieval Behavior

**Input:** Agent context where a tool result was spilled, and the subsequent task requires detail from the full result.
**Expected:** Agent uses `cache_read` to retrieve the full result rather than guessing from the summary.

This is a behavior eval — the agent must recognize when the summary isn't enough and proactively fetch.

**Pass rate:** 85% over 20 iterations

### 7.3 Threshold Calibration

**Methodology:** Grid search, not guessing. Run per-tool against a task battery:

1. Build 20 realistic tasks where the agent needs tool results: file reads, grep searches, directory listings
2. For each tool, test thresholds at [2k, 4k, 8k, 12k, 16k, 24k] tokens
3. Measure per threshold:
   - Task completion rate (did the agent produce the correct answer?)
   - Context window consumption (tokens used by tool results at turn N)
   - Cache retrieval rate (what fraction of `cache://` references did the agent follow?)
   - Cost (fewer spills = larger context = higher cost per turn)
4. Plot the knee in the tradeoff curve — that's the default threshold
5. Run separately per tool (grep vs read have different information densities)

Results populate the per-tool threshold config. This eval is expensive (~$20-30 per full grid run) and runs only during calibration, not on every push.

## Fixtures

- Tool results at varying sizes (500, 2k, 5k, 15k tokens) from grep, read, ls
- Agent contexts with spilled tool results requiring cache retrieval
- Realistic task batteries for threshold calibration (20 tasks per tool)
