# Actor Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [harness](../../harness.md) |

## Test Cases

### 4.1 Observation Usage

**Input:** Observations containing "User prefers argon2" + prompt "implement the login endpoint."
**Expected:** Response references argon2, not bcrypt.

**Pass rate:** 85% over 20 iterations

### 4.2 Continuation After Trimming

**Input:** Observations + continuation hint + 3 tail messages (simulating mid-conversation after message trimming).
**Expected:** Actor continues naturally. No greeting. References current task.

**Pass rate:** 90% over 20 iterations

### 4.3 Tool Selection

| Prompt | Expected tool | Must NOT use |
|--------|--------------|-------------|
| "Read src/auth.ex" | `read` | `bash` |
| "Find all test files" | `find` | `bash` |
| "Search for 'defmodule Auth'" | `grep` | `bash` |
| "Run the tests" | `bash` with `mix test` | — |
| "Change foo to bar in config.exs" | `edit` | `bash` |

Guard: assert the response contains a tool call at all before checking which tool. A prose-only response is a distinct failure from calling the wrong tool.

**Pass rate:** 85% over 20 iterations

## Fixtures

- Observation sets with user preferences for observation usage tests
- Trimmed conversation contexts with continuation hints
- Simple task prompts for tool selection testing
