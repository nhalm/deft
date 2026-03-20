# Observational Memory

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Ready |
| Last Updated | 2026-03-19 |

## Changelog

### v0.3 (2026-03-19)
- Clarified token estimation: must use `String.length` (character count), not `byte_size` (byte count) — multi-byte characters inflate estimates
- Clarified keep_tail: must skip oversized messages and continue, not halt on first oversized message
- Clarified: OM threshold config fields from section 8 must be wired through `Deft.Config`

### v0.2 (2026-03-18)
- Fix spec/code divergence: OM state is persisted as a separate `<session_id>_om.jsonl` file, not entries in the session JSONL (spec section 9). This was a deliberate implementation choice to avoid JSONL write interleaving when session and OM systems write concurrently.

### v0.1 (2026-03-16)
- Initial spec — observational memory system for Deft with sectioned observations, Task-based Observer/Reflector, async buffering with epoch-based staleness, user correction via /forget and /correct commands

## Overview

Observational memory (OM) is Deft's core differentiator. It solves the fundamental problem of LLM context window amnesia: when conversations grow long, traditional agents either truncate history (losing information) or do naive summarization (losing nuance).

OM works like human memory. Instead of storing raw conversation transcripts, it continuously extracts structured observations — facts, decisions, preferences, context — and maintains them as an always-current narrative. This narrative is injected into every LLM turn, giving the Actor agent the illusion of perfect recall regardless of conversation length.

The design is inspired by Mastra's observational memory system, adapted for Elixir/OTP's process model where the Observer and Reflector are independent supervised processes communicating via messages rather than async promises with mutex locks.

**Scope:**
- Observer process — extracts observations from raw messages
- Reflector process — compresses observations when they grow too large
- Context injection — inserting observations into the Actor's context window
- Message trimming — removing observed messages from context
- Token threshold management — when to observe and when to reflect
- Async buffering — pre-computing observations in the background
- Observation persistence — saving/restoring OM state across session resume

**Out of scope:**
- The Actor agent loop itself (see [harness.md](harness.md))
- Semantic search / vector embeddings (deliberately excluded — OM is always-present, not retrieval-based)
- Cross-session memory / resource scope (future)
- Secret detection / redaction in observations (future — no security layer in v0.1)
- Hybrid retrieval (always-present summary + selective detail injection — future if 40k flat injection proves insufficient)

**Dependencies:**
- [harness.md](harness.md) — agent loop, provider layer, session persistence, process architecture

**Design principles:**
- **No retrieval.** The full observation text is injected every turn. There is no query, no embedding, no search. What is stored is what the agent sees.
- **Two-level compression.** Raw messages → observations (first compression). Observations → reflected observations (second compression). Each level reduces tokens while preserving the most important information.
- **Non-blocking by default.** Observation and reflection run in background processes. The Actor never waits for OM unless a hard threshold is exceeded.
- **Process isolation.** Observer and Reflector are separate OTP processes. They cannot crash the Actor. They communicate via messages, not shared state.

## Specification

### 1. Process Architecture

OM runs as a subtree within each session's supervision tree, under `Deft.OM.Supervisor`:

```
Deft.OM.Supervisor (Supervisor, rest_for_one)
├── Deft.OM.TaskSupervisor (Task.Supervisor — runs Observer/Reflector LLM calls)
└── Deft.OM.State (GenServer — owns observation state, spawns Tasks for LLM work)
```

Note: TaskSupervisor starts BEFORE State. With `rest_for_one`, if TaskSupervisor crashes, State also restarts with clean flags (no stale `is_observing`/`is_reflecting`). If State crashes, TaskSupervisor is unaffected (orphaned Tasks get `:DOWN` messages to nobody, which is harmless).

**Process roles:**

| Process | Responsibility |
|---------|---------------|
| `Deft.OM.State` | Owns the canonical observation state. All reads and writes go through this process. Spawns Tasks under TaskSupervisor for Observer/Reflector LLM calls. Handles results via `handle_info`. |
| `Deft.OM.TaskSupervisor` | Supervises Observer and Reflector Tasks. Tasks are spawned via `Task.Supervisor.async_nolink` so failures don't crash State. |

Observer and Reflector are **not persistent processes** — they are functions invoked as Tasks when needed. This avoids the GenServer anti-pattern of blocking on long-running LLM calls and simplifies the architecture. State coordinates all OM work and delegates LLM calls to Tasks.

**Interaction with the Agent:**

The Agent (from harness spec) interacts with OM at two points:
1. **Before each LLM call:** Agent calls `Deft.OM.State.get_context/1` to get the current observations text and the list of message IDs that have been observed (and can be trimmed from context).
2. **After each turn:** Agent calls `Deft.OM.State.messages_added/2` with the new messages and their estimated token counts. State notifies Observer if thresholds are approaching.

### 2. Observation State

The State process holds a struct with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `active_observations` | `String.t()` | The current observation text, injected into every turn |
| `observation_tokens` | `integer()` | Estimated token count of `active_observations` |
| `buffered_chunks` | `[BufferedChunk.t()]` | Pre-computed observation chunks not yet activated |
| `buffered_reflection` | `String.t() \| nil` | Pre-computed reflection not yet activated |
| `last_observed_at` | `DateTime.t() \| nil` | Timestamp of the last observed message |
| `observed_message_ids` | `[String.t()]` | IDs of messages that have been observed |
| `pending_message_tokens` | `integer()` | Token count of unobserved messages |
| `generation_count` | `integer()` | Number of reflection cycles completed |
| `is_observing` | `boolean()` | Whether an observation cycle is in flight |
| `is_reflecting` | `boolean()` | Whether a reflection cycle is in flight |
| `needs_rebuffer` | `boolean()` | Buffer interval crossed while Observer in flight; re-observe all pending on completion |
| `activation_epoch` | `integer()` | Monotonic counter incremented on BOTH observation and reflection activation; stale-epoch chunks/reflections discarded |
| `snapshot_dirty` | `boolean()` | Set on any state mutation, cleared after snapshot write; 60s timer checks this flag |
| `calibration_factor` | `float()` | Token estimation calibration (chars per token), default 4.0, updated from provider usage reports |
| `sync_from` | `GenServer.from() \| nil` | Stashed caller for sync fallback; reply via `GenServer.reply/2` from `handle_info` |

A `BufferedChunk` contains:

| Field | Type | Description |
|-------|------|-------------|
| `observations` | `String.t()` | The observation text for this chunk |
| `token_count` | `integer()` | Token count of the observation text |
| `message_ids` | `[String.t()]` | Which messages this chunk covers |
| `message_tokens` | `integer()` | Raw message token count this chunk compressed |

### 3. Observer

The Observer extracts structured observations from raw conversation messages.

#### 3.1 Trigger Conditions

The Observer activates when `pending_message_tokens` reaches the observation threshold (default: 30,000 tokens).

With async buffering enabled (default), the Observer also runs at buffer intervals — by default every 20% of the threshold (6,000 tokens) — to pre-compute observations in the background.

#### 3.2 Observer Input

The Observer receives:
1. **Existing observations** — a token-budgeted excerpt of `active_observations` (default budget: 8,000 tokens). Prioritizes: most recent observations (tail), then high-priority (🔴) lines from older content. The larger budget (vs Mastra's 2k) reduces duplicate extraction by giving the Observer visibility into ~40% of typical observation content.
2. **New messages** — the unobserved messages, formatted as timestamped role-labeled text.

#### 3.3 Message Formatting

Messages are formatted for the Observer as:

```
**User (14:32):**
explain the auth module

**Assistant (14:32):**
The auth module handles JWT-based authentication...

**Assistant (14:32) [Tool Call: read]:**
src/auth.ex

**Assistant (14:32) [Tool Result: read]:**
defmodule Auth do
  ...
end
```

- Each message includes the role and wall-clock timestamp from the message metadata
- Tool calls show the tool name and arguments
- Tool results show the tool name and output (truncated if very long)
- Image attachments are noted as `[Image: filename.png]`

#### 3.4 Extraction Rules

The Observer system prompt instructs the LLM to extract observations following these rules:

**What to extract:**
- User assertions and facts ("we use PostgreSQL", "our API is REST") — marked 🔴 (high priority)
- User preferences — stated or demonstrated preferences about workflow, style, tools — marked 🔴
- **Files read and modified** — record file paths and their purpose/key contents (e.g., "Read `src/auth.ex` — contains JWT verification with `verify_token/1`") — marked 🟡
- **Errors encountered** — record error messages verbatim, what caused them, and whether they were resolved — marked 🟡
- **Commands run and outcomes** — what bash commands were executed and their result (pass/fail, key output) — marked 🟡
- **Architectural decisions with rationale** — not just "chose gen_statem" but "chose gen_statem because the agent loop has distinct states" — marked 🟡
- **Build/test state** — what passes, what fails, what was last run — marked 🟡
- Conversation outcomes — decisions made, approaches chosen, problems solved
- State changes — "User will start doing X (changing from Y)"
- **Dependencies and versions** — packages added/removed/upgraded (e.g., "Added jason ~> 1.4 to deps") — marked 🟡
- **Git state** — branch name, recent commits mentioned, merge conflicts — marked 🟡
- **Deferred work / TODOs** — things the user said to come back to ("we still need to handle the error case") — marked 🟡

**Anti-hallucination rules:**
- Only record information that is directly stated or demonstrated in the messages. Do NOT infer unstated facts.
- If an observation is uncertain, prefix it with "Likely:" (e.g., "Likely: user's project uses Phoenix based on deps")
- If the user asks a hypothetical question, do NOT record it as a fact.
- When in doubt, omit the observation rather than fabricate one.

**Priority levels:**
- 🔴 **High** — explicit user facts, user-stated preferences, completed goals, critical context
- 🟡 **Medium** — project details, tool results, learned information
- 🟢 **Low** — minor details, uncertain observations

**Format:** Observations are organized into **named sections**, not a flat chronological list. This improves LLM attention patterns within large observation blocks and makes `/observations` output readable.

Standard sections (Observer outputs into these):

```
## Current State
- (14:55) Active task: implementing JWT verification in src/auth.ex
- (14:55) Last action: Runner created User migration
- (14:52) Blocking error: none

## User Preferences
- (14:32) 🔴 User wants minimal dependencies — prefers standard library over third-party
- (14:35) 🔴 User prefers YAML over TOML for config

## Files & Architecture
- (14:40) 🟡 Read src/auth.ex — contains JWT module with verify_token/1
- (14:45) 🟡 Modified src/auth.ex — added refresh_token/1 function
- (14:42) 🟡 Architecture: gen_statem for agent loop, Task-based Observer/Reflector

## Decisions
- (14:40) 🟡 Chose argon2 for password hashing (OWASP recommendation)
- (14:33) 🟡 Chose Breeze for TUI (LiveView-style API, Gazler's Termite stack)

## Session History
- (14:32) 🔴 User stated they are building an Elixir coding agent called Deft
- (14:33) 🟡 User asked about TUI options for Elixir
- (14:45) 🟡 Tests passing after auth module refactor
```

The `## Current State` section is always at the top (highest attention position). It is regenerated by the Observer on each cycle, not accumulated. `## Session History` carries the chronological log and bears the brunt of Reflector compression. The Reflector compresses within sections, preserving the section structure.

**Temporal anchoring:**
- Each observation carries a wall-clock timestamp from the source message
- Relative time references ("last week", "next Thursday") are converted to estimated calendar dates in parentheses at the end
- Vague references ("recently") are NOT given estimated dates

**What NOT to extract:**
- Verbatim conversation flow ("User said X, Assistant replied Y") — extract the facts, not the dialogue
- Internal reasoning or chain-of-thought
- Redundant information already in existing observations

#### 3.5 Observer Output

The Observer LLM returns structured XML:

```xml
<observations>
## Current State
- (14:55) Active task: ...

## User Preferences
...

## Session History
...
</observations>

<current-task>
Building the observational memory spec for Deft
</current-task>
```

The `<observations>` block is parsed and merged into `active_observations` using **section-aware merge rules**:

| Section | Merge strategy |
|---------|---------------|
| `## Current State` | **Replace** — new output overwrites the existing section entirely (regenerated each cycle) |
| `## User Preferences` | **Append** — new entries added to end of section |
| `## Files & Architecture` | **Append with dedup** — if the same file path already has an entry, update it (don't add duplicate). Distinguish "Read" vs "Modified" entries. |
| `## Decisions` | **Append** |
| `## Session History` | **Append** |
| Unknown sections | **Ignore** — do not create new sections outside the standard set |

The same section-aware merge is used when activating buffered chunks (Section 6.1) — chunks are NOT naively concatenated. Each chunk's sections are merged individually.

The `<current-task>` is folded into the `## Current State` section (single source of truth — no separate `<current-task>` injection).

Note: `<suggested-response>` was removed — a cheap model should not steer the expensive Actor's behavior. The dynamic continuation hint (Section 5.3) provides conversation continuity without this risk.

If XML parsing fails, fall back to extracting raw bullet-list content from the response.

#### 3.6 Observer Model

The Observer uses a configurable model, separate from the Actor model. Default: `claude-haiku-4.5`. The Observer calls the same provider layer as the Actor (from harness spec) but with its own model configuration.

Observer model settings: `temperature: 0.0` (extraction is mechanical, no randomness needed), max output tokens: 16,000 (realistic cap — Observer output should never exceed this; catches runaway generation early).

### 4. Reflector

The Reflector compresses observations when they grow too large for the context window.

#### 4.1 Trigger Conditions

The Reflector activates when `observation_tokens` reaches the reflection threshold (default: 40,000 tokens).

With async buffering enabled (default), the Reflector pre-computes a reflection when observations reach 50% of the threshold (20,000 tokens).

#### 4.2 Reflector Input

The Reflector receives the full `active_observations` text.

#### 4.3 Compression Strategy

The Reflector system prompt instructs the LLM to compress observations with escalating aggressiveness:

| Level | Trigger | Guidance |
|-------|---------|----------|
| 0 | First attempt | No specific compression guidance — let the LLM decide what to drop |
| 1 | Level 0 output still > threshold | Merge related observations, drop 🟢 items older than 1 day |
| 2 | Level 1 output still > threshold | Aggressively merge, drop all 🟢 items, summarize 🟡 groups |
| 3 | Level 2 output still > threshold | Maximum compression — keep only 🔴 items and most recent day |

The Reflector's **target size** is 50% of the reflection threshold (default: 20,000 tokens). It tries level 0 first with this target specified in the prompt. If the output exceeds the target, it retries at the next level, up to level 3. Maximum 2 LLM calls (combine the compression level and target in a single prompt; retry once if output still exceeds target). If level 3 still exceeds the threshold, accept the output and move on — do not loop indefinitely. Log a warning.

#### 4.4 Reflector Output

The compressed observations replace `active_observations`. The `generation_count` is incremented. Section structure and ordering MUST be preserved: Current State, User Preferences, Files & Architecture, Decisions, Session History. The Reflector MUST NOT reorder sections.

**CORRECTION marker survival check:** After compression, verify all CORRECTION markers from the input appear in the output. If any are missing, append them to the appropriate section. This prevents corrected false observations from resurfacing.

**Per-section budget guidance for the Reflector prompt:** Current State ~500 tokens, User Preferences ~1k, Files & Architecture ~8k, Decisions ~3k, Session History gets the remainder. This prevents over-preserving verbose Session History at the expense of structured sections.

#### 4.6 Hard Observation Cap

If `observation_tokens` exceeds 60,000 tokens (1.5x reflection threshold) despite Reflector failures, truncate from the **head of Session History** (oldest chronological entries) until under the cap. Preserve all other sections intact. Preserve all CORRECTION markers regardless of position. Log a warning event `{:om, :hard_cap_truncation, %{before: n, after: m}}`.

#### 4.5 Reflector Model

Same configurable model as the Observer. Default: `claude-haiku-4.5`. Settings: `temperature: 0`, max output tokens: 100,000.

### 5. Context Injection

On every Agent turn, before calling the LLM, the context is assembled with OM content:

#### 5.1 Observation System Message

If `active_observations` is non-empty, an additional system message is injected containing:

1. **Preamble** — instructs the Actor that the following are observations from the conversation so far, and to treat them as memory
2. **Observations block** — the full `active_observations` text wrapped in `<observations>` tags
3. **Instructions** — tells the Actor to: prefer recent information when facts conflict (using timestamps), treat planned actions as completed if their dates have passed, personalize responses using specific details. Treat "Likely:" prefixed observations as low-confidence. Do not proactively explain the observation system but answer honestly if the user asks how you remember things.
4. **Current task** — if set, a `<current-task>` block

Conflict resolution instructions are placed in the **main system prompt** (not in the observation block, where they'd compete for attention in a 40k block):
- "If observations conflict with the current conversation messages, the messages take precedence."
- "If observations conflict with DEFT.md/CLAUDE.md project instructions, the project instructions take precedence."

#### 5.2 Message Trimming

Messages whose IDs appear in `observed_message_ids` are removed from the conversation history before sending to the LLM. This frees context window space — the observations are a compressed representation of those messages.

A small number of recent messages (the "tail") are always kept in context even if observed, to maintain conversational continuity. The tail size is the lesser of: 20% of the observation threshold (default: 6,000 tokens) or the actual unobserved messages.

#### 5.3 Continuation Hint

When observations are present and observed messages have been trimmed, a special user message is injected after the observations to prevent the Actor from behaving as if the conversation just started:

The continuation hint is **dynamic**, generated by the Observer alongside observations. It includes: the current task, the last action taken (last tool call), and a paraphrase of the user's last request. Example:

> "You were debugging a compilation error in `src/auth.ex`. Your last action was editing that file to add the missing `verify_token/1` function. The user asked you to run the tests to verify the fix."

If no Observer-generated hint is available, fall back to a static message: "Continue the conversation naturally. You have observations from earlier in this conversation available above."

### 6. Async Buffering

Async buffering pre-computes observations and reflections in the background so that when a threshold is reached, activation is instant (no blocking LLM call on the hot path).

#### 6.1 Observation Buffering

- **Buffer interval:** Every 20% of the observation threshold (default: every 6,000 tokens of new messages)
- **Process:** When `pending_message_tokens` crosses a buffer interval, State spawns an Observer Task via `Deft.OM.TaskSupervisor`. The Task runs the LLM call and sends the result back to State as a `BufferedChunk`.
- **Coalescing:** State MUST NOT spawn a new Observer Task while one is in flight (`is_observing == true`). Instead, it sets a `needs_rebuffer` flag. When the current Task completes, State checks the flag and spawns a new Task if needed. This bounds in-flight work to exactly one Observer call at a time.
- **Late-arriving chunks:** State tracks an `activation_epoch` counter, incremented on each activation. Buffered chunks carry the epoch they were started in. Chunks arriving with a stale epoch are discarded.
- **Activation:** When `pending_message_tokens` reaches the full observation threshold, all `buffered_chunks` are concatenated and appended to `active_observations` instantly — no LLM call needed.
- **Tail retention:** After activation, a configurable fraction of the most recent raw messages are kept unobserved (default: 20% of threshold = 6,000 tokens worth). This provides a sliding window of recent conversation for the Actor.

#### 6.2 Reflection Buffering

- **Buffer trigger:** When `observation_tokens` reaches 50% of the reflection threshold (default: 20,000 tokens), State spawns a Reflector Task. The Task carries the current `activation_epoch`.
- **Activation:** When `observation_tokens` reaches the full threshold and `buffered_reflection` is non-nil, check the epoch. If stale (epoch has changed since the reflection was started), discard the reflection and re-trigger. If current, replace `active_observations` instantly.

#### 6.4 Observer/Reflector Serialization

Observer and Reflector MUST NOT run concurrently. If the Reflector replaces `active_observations` while the Observer is in flight, the Observer's output was computed against stale pre-reflection observations.

Rule: if `is_reflecting == true`, do not activate Observer results. Buffer them and activate after reflection completes. Conversely, if `is_observing == true`, defer reflection until the Observer completes. `activation_epoch` is incremented on BOTH observation activation AND reflection activation — stale results from either are discarded.

#### 6.3 Hard Threshold (Sync Fallback)

If async buffering fails or hasn't completed and tokens exceed `1.2x` the threshold (default: 36,000 for observation, 48,000 for reflection), a **synchronous** observation/reflection is forced.

**Sync fallback design (avoids deadlock):** The Agent calls `GenServer.call(State, :force_observe, 60_000)`. State stores the caller's `from` in its state, spawns an Observer Task, and returns `{:noreply, state}`. When the Task completes and delivers results via `handle_info({ref, result})`, State calls `GenServer.reply(from, result)`. This is the standard from-stashing pattern — State is never blocked and remains responsive to other calls during the wait.

The Agent should handle this asynchronously if possible (cast + handle_info) to remain responsive to abort signals. If using GenServer.call, the 60-second timeout is the safety net — on timeout, the Agent proceeds without observation and logs a warning.

**Sync Observer uses 1 retry max** (not 3). The sync path exists because the system is behind — spending time on retries defeats the purpose.

**LLM failure recovery:** Observer/Reflector Tasks retry up to 3 times with exponential backoff (async path) or 1 retry (sync path). After failures, the cycle is skipped — State clears `is_observing`/`is_reflecting` and emits `{:om, :cycle_failed, %{type: t, reason: reason}}`. The system continues without that observation/reflection cycle.

**Sync fallback failure:** If the sync Task fails or times out, State receives `{:DOWN, ref, :process, _pid, reason}` in `handle_info`. If `sync_from` is stashed, State calls `GenServer.reply(sync_from, {:error, reason})`, clears `sync_from`, and clears in-flight flags. The Agent receives the error immediately — no silent 60-second hang.

**Circuit breaker:** After 3 consecutive cycle failures (not retries — 3 full cycles that all failed), State enters degraded mode: stops attempting observation/reflection entirely. Emits `{:om, :circuit_open}`. Resumes after a 5-minute cooldown or on explicit user action (`/compact` command). TUI shows degraded state.

### 7. Token Estimation

Token counts are estimated using a character-based heuristic: `tokens ≈ character_count / 4`. This avoids requiring a tokenizer dependency.

Actual token counts from provider usage reports (`:usage` events) are used to calibrate the estimate when available. The calibration factor is stored in state and updated with an exponential moving average.

### 8. Configuration

All OM configuration lives under the `om` namespace in Deft's config:

| Field | Default | Description |
|-------|---------|-------------|
| `om.enabled` | `true` | Enable/disable OM |
| `om.observer_model` | `"claude-haiku-4.5"` | Model for Observer |
| `om.reflector_model` | `"claude-haiku-4.5"` | Model for Reflector |
| `om.observer_provider` | `"anthropic"` | Provider for Observer |
| `om.reflector_provider` | `"anthropic"` | Provider for Reflector |
| `om.message_token_threshold` | `30_000` | Tokens of unobserved messages before observation triggers |
| `om.observation_token_threshold` | `40_000` | Tokens of observations before reflection triggers |
| `om.buffer_interval` | `0.2` | Fraction of message threshold for async buffer intervals |
| `om.buffer_tail_retention` | `0.2` | Fraction of threshold to keep as raw messages after activation |
| `om.hard_threshold_multiplier` | `1.2` | Multiplier for sync fallback threshold |
| `om.previous_observer_tokens` | `8_000` | Token budget for passing existing observations to Observer |
| `om.observer_temperature` | `0.0` | Temperature for Observer LLM calls |
| `om.reflector_temperature` | `0.0` | Temperature for Reflector LLM calls |

### 9. Persistence

OM state is persisted as a snapshot in a separate `<session_id>_om.jsonl` file, not embedded in the session JSONL. This separate file avoids write contention when the session store and OM systems write concurrently.

#### 9.1 When to Save

An `observation` entry is appended to the session JSONL:
- After each observation activation (buffered chunks applied)
- After each reflection activation
- **Periodically** — every 60 seconds if state has changed (narrows the data loss window on crash)
- On session shutdown (graceful save of current state)

#### 9.2 What to Save

The `observation` entry contains a full snapshot of the OM state: `active_observations`, `observation_tokens`, `observed_message_ids`, `pending_message_tokens`, `generation_count`, `last_observed_at`, `activation_epoch`, and `calibration_factor`.

Buffered chunks and in-flight state (`is_observing`, `is_reflecting`, `needs_rebuffer`) are NOT persisted — they are transient and will be recomputed on resume.

#### 9.3 Session Resume

When resuming a session:
1. Load the latest `observation` entry from the JSONL
2. Initialize `Deft.OM.State` with the restored state
3. Recompute `pending_message_tokens` by iterating the message list and counting tokens for messages whose IDs are NOT in `observed_message_ids` (use message IDs as the authoritative boundary, not timestamps — avoids ambiguity when messages share the same timestamp)
4. If thresholds are already exceeded, trigger observation/reflection immediately

### 10. Observability

OM broadcasts events via the session's Registry (same mechanism the TUI uses for agent events):

| Event | When |
|-------|------|
| `{:om, :observation_started}` | Observer LLM call begins |
| `{:om, :observation_complete, %{tokens_observed: n, tokens_produced: m}}` | Observer cycle done |
| `{:om, :reflection_started, %{level: n}}` | Reflector LLM call begins |
| `{:om, :reflection_complete, %{before_tokens: n, after_tokens: m}}` | Reflector cycle done |
| `{:om, :buffering_started, %{type: :observation \| :reflection}}` | Async buffer cycle begins |
| `{:om, :buffering_complete, %{type: :observation \| :reflection}}` | Async buffer cycle done |
| `{:om, :activation, %{type: :observation \| :reflection}}` | Buffered content activated |
| `{:om, :sync_fallback, %{type: :observation \| :reflection}}` | Hard threshold exceeded, sync cycle forced |

These events are used by the TUI status bar to show OM activity and by the session JSONL for debugging.

### 11. User Interaction

Users interact with observations via slash commands:

- **`/observations`** — displays a summary: `## Current State` + `## User Preferences` + today's entries. Use `/observations --full` for the complete dump. Use `/observations --search <term>` to filter.
- **`/forget <text>`** — searches observations for matches, shows the matching observation(s), asks for confirmation before appending a CORRECTION marker: `- (HH:MM) 🔴 CORRECTION: [text] is incorrect — remove this observation`. The Reflector treats CORRECTION markers as highest priority and MUST preserve them through compression. A post-compression check verifies all CORRECTION markers from the input survive in the output.
- **`/correct <old> → <new>`** — searches for `<old>` in observations, shows the match, asks for confirmation, appends: `- (HH:MM) 🔴 CORRECTION: Replace "[old]" with "[new]"`.
- **Natural language corrections** ("forget that", "that's wrong") are also supported as a convenience — the Agent detects correction intent and invokes the same mechanism. But the slash commands are the reliable path.

This replaces the earlier "never mention OM" rule. The system is transparent: it does not proactively explain itself, but it answers honestly when asked and gives users control over their observations.

## Notes

### Design decisions

- **No embeddings / no retrieval.** This is the most important design decision. Retrieval-augmented memory requires a query to surface relevant facts, which means the agent must know what it doesn't know. OM takes the opposite approach: everything observed is always present. The token cost is managed by two-level compression, not by selective retrieval.
- **Cheap model for Observer/Reflector.** Observation and reflection are mechanical tasks — extracting facts and compressing text. They don't require the intelligence of the Actor model. Using Haiku (or Gemini Flash, or GPT-4o-mini) keeps OM cost-effective.
- **Per-session scope only for v0.1.** Cross-session memory (Mastra's "resource scope") is valuable but adds complexity around merging observations across threads. Deferred to a future version.
- **Character-based token estimation.** A real tokenizer (tiktoken, etc.) would be more accurate but adds a dependency and is slow for large texts. The 4:1 ratio is a well-known approximation that works well enough for threshold decisions. Calibration from actual usage reports improves accuracy over time.

### Differences from Mastra

| Aspect | Mastra | Deft |
|--------|--------|------|
| Runtime | Node.js with static Maps and mutexes | Elixir/OTP with isolated processes |
| Buffering | Promise-based with complex activation logic | Process messages — Observer sends chunks to State |
| State management | Shared mutable state with sealing/locking | State process owns all data, accessed via messages |
| Message sealing | Metadata flags on messages to prevent re-observation | Message ID tracking in State process |
| Provider | Google Gemini Flash (hardcoded default) | Configurable, any provider from harness layer |
| Scope | Thread and resource (cross-thread) | Thread only (v0.1) |
| Token counting | `tokenx` library with model-specific image counting | Character heuristic with calibration |

### Resolved

- **Observer prompt tuning.** Added coding-specific extraction categories and named sections.
- **Cost tracking.** Tracked in harness layer. Negligible (~$0.15-0.20 per long session).
- **Process architecture.** Observer/Reflector are Tasks spawned by State. Eliminates blocking.
- **Observation sectioning.** Promoted to requirement. Named sections with `## Current State` at top.
- **`<suggested-response>`.** Removed. Cheap model should not steer expensive Actor.
- **Observer/Reflector serialization.** Must not run concurrently. Epoch incremented on both activation types.
- **Sync fallback.** Uses from-stashing pattern, 1 retry max, 60s timeout.
- **40k reflection threshold.** Validated by Mastra's empirical testing.
- **First-activation threshold.** Keep at 30k — lowering not worth the cost for short sessions.

### Open questions (resolve before Ready)

- **Reflection quality.** Need to verify compressed observations retain enough detail. Test with multi-hour coding sessions.
- **Token budget sharing.** Mastra's `shareTokenBudget` option — worth considering but adds complexity.
- **Tail retention size.** Currently 20% (6k tokens). Context Expert recommends 30% (9k) since a single file read can be 3-4k tokens. Needs testing.
- **Hard observation cap.** Should there be a max (e.g., 60k tokens) beyond which observations are truncated from the head, even if the Reflector failed? Prevents unbounded growth in degenerate cases.

## References

- [Mastra Observational Memory source](https://github.com/mastra-ai/mastra/tree/main/packages/memory/src/processors/observational-memory) — primary inspiration
- [harness.md](harness.md) — Deft foundation spec (agent loop, providers, sessions)
