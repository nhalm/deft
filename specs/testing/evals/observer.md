# Observer Evals

| | |
|--------|------|
| Parent | [evals](README.md) |
| Spec | [observational-memory](../../observational-memory.md) |

## Test Cases

### 2.1 Fact Extraction

**Input:** Conversation fixture where the user states explicit facts.

| Test case | Input (user says) | Must contain | Priority |
|-----------|-------------------|-------------|----------|
| Explicit tech choice | "We use PostgreSQL for our database" | "PostgreSQL" | 🔴 |
| Preference statement | "I prefer spaces over tabs" | "spaces" AND "prefer" | 🔴 |
| File read | [Tool result: contents of src/auth.ex] | File path "src/auth.ex" | 🟡 |
| File modification | [Tool call: edit src/auth.ex] | "Modified" AND "src/auth.ex" | 🟡 |
| Error encountered | [Bash output: CompileError in line 42] | Error message verbatim (or close) | 🟡 |
| Command run | [Bash: mix test → 12 tests, 2 failures] | "mix test" AND "2 failures" | 🟡 |
| Architectural decision | "Let's use gen_statem for the agent loop because it has explicit states" | "gen_statem" AND rationale | 🟡 |
| Dependency added | "Add jason ~> 1.4 to the deps" | "jason" AND version | 🟡 |
| Deferred work | "We still need to handle the error case later" | "error case" AND deferred/TODO | 🟡 |

**Pass rate:** 85% over 20 iterations

### 2.2 Section Routing

| Fact type | Expected section |
|-----------|-----------------|
| User preference | `## User Preferences` |
| File read/modify | `## Files & Architecture` |
| Implementation decision | `## Decisions` |
| Current task description | `## Current State` |
| General conversation event | `## Session History` |

**Pass rate:** 85% over 20 iterations

### 2.3 Anti-Hallucination

| Test case | User says | Must NOT be extracted as fact |
|-----------|-----------|------------------------------|
| Hypothetical | "What if we used Redis?" | "User chose Redis" |
| Exploring options | "Should we use bcrypt or argon2?" | "User chose bcrypt/argon2" |
| Reading about something | [Reads a file about MongoDB] | "User uses MongoDB" |
| Discussing alternatives | "One option would be to use WebSockets" | "User will use WebSockets" |

Anti-hallucination fixtures must include the tempting content substantively in the conversation, not just mention it in passing.

**Pass rate:** 95% over 20 iterations

### 2.4 Deduplication

**Input:** Existing observations + new messages repeating already-observed facts.
**Expected:** No re-extraction of facts already present.

**Pass rate:** 80% over 20 iterations

### 2.5 Read vs Modified Tracking

**Input:** Conversation where the agent reads a file, then later modifies it.
**Expected:** `## Files & Architecture` distinguishes read from modified with relevant detail.

**Pass rate:** 80% over 20 iterations

## Fixtures

- Conversation fixtures with explicit user statements (tech choices, preferences)
- Tool result fixtures (file reads, bash output, edit calls)
- Anti-hallucination fixtures with tempting hypothetical/exploratory content
- Existing observation sets for dedup testing
- File read-then-modify conversation sequences
