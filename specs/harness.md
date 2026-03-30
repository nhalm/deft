# Harness

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Implemented |
| Last Updated | 2026-03-29 |

## Changelog

### v0.3 (2026-03-29)
- Added sub-agent mode: `Deft.Agent` can be started as a child of an orchestrator process, not just as a top-level session agent. The agent is the same — the supervision context differs.
- Updated supervision tree to show both standalone (session) and orchestrated (job) modes
- Removed tuple-state reference from design decisions — orchestration no longer extends the agent via tuple states

### v0.2 (2026-03-19)
- Clarified: abort in `:executing_tools` must terminate all per-tool inner tasks, not just the outer wrapper task
- Clarified: `om_enabled` default must be consistent across all code paths (default `true`)
- Clarified: turn counter must include the initial prompt-triggered LLM call in the count

### v0.1 (2026-03-16)
- Initial spec — agent loop (gen_statem), canonical message format, process architecture, context assembly

## Overview

The harness is the core runtime of Deft — the agent loop that receives prompts, calls the LLM, executes tools, and loops. It defines the canonical message format used by every other layer and the process architecture that hosts sessions.

This is a focused spec. Tools, providers, sessions, TUI, and orchestration are specified separately.

**Scope:**
- Process architecture (supervision tree, session lifecycle)
- Agent loop (gen_statem states and transitions)
- Canonical message format (`Deft.Message` and content blocks)
- Context assembly (message list construction per turn)
- Token tracking and compaction fallback

**Out of scope:**
- Tool definitions and execution (see [tools.md](tools.md))
- LLM provider abstraction (see [providers.md](providers.md))
- Session persistence and config (see [sessions.md](sessions.md))
- Terminal UI (see [tui.md](tui.md))
- Observational memory (see [observational-memory.md](observational-memory.md))
- Orchestration (see [orchestration.md](orchestration.md))
- Tool permission / approval system (future)

**Dependencies:**
- [standards.md](standards.md) — coding standards, project structure

## Specification

### 1. Process Architecture

The application runs as a supervised OTP application:

```
Deft.Application (Application)
└── Deft.Supervisor (Supervisor, one_for_one)
    ├── Deft.Provider.Registry (GenServer — provider config/state)
    └── Deft.Session.Supervisor (DynamicSupervisor)
        └── per-session children (started on demand):
            Deft.Session.Worker (Supervisor, rest_for_one)
            ├── Deft.Agent (gen_statem — the agent loop)
            ├── Deft.Agent.ToolRunner (Task.Supervisor — tool execution)
            └── Deft.OM.Supervisor (Supervisor — observational memory processes)
```

**Standalone mode** (above) is for direct user sessions — one Agent per session. This is the default.

**Sub-agent mode:** `Deft.Agent` can also be started as a child of an orchestrator process (Foreman, Lead) within a job supervision tree. In this mode:

- The Agent is started with a `parent_pid` option, which is passed through to `ToolContext` for orchestration tools
- The orchestrator process is responsible for sending prompts to the Agent via `Deft.Agent.prompt/2`
- The Agent broadcasts events via Registry as usual — the orchestrator and web UI both subscribe
- Multiple Agents can coexist in the same job (one ForemanAgent + N LeadAgents), each with their own ToolRunner and OM
- The `rest_for_one` strategy applies within each Agent's sub-tree (Agent + ToolRunner + OM), not at the job level. If a sub-agent crashes, its orchestrator detects the crash via `Process.monitor` and handles recovery.

See [orchestration.md](orchestration.md) for the job-level supervision tree.

Key invariants:
- Each session is an isolated process subtree. A crash in one session does not affect others.
- `rest_for_one` strategy on the session worker (standalone) or agent sub-tree (sub-agent): if the Agent crashes, ToolRunner and OM processes restart too.
- The Agent process owns the conversation state. All access is via message passing.
- Tool execution happens in supervised tasks (`Task.Supervisor.async_nolink`). A tool crash returns an error result; it does not crash the agent.
- The Agent is the same `gen_statem` in both modes. It does not know whether it's standalone or orchestrated — it just processes prompts and executes tools.

### 2. Agent Loop

The agent is a `gen_statem` using `handle_event` callback mode (allows fallback handlers in any state) with four states:

```
:idle ──prompt──▶ :calling ──stream_start──▶ :streaming ──stream_end──▶ :executing_tools ──done──▶ :idle
                                                                              │
                                                                              ├──more_tool_calls──▶ :calling
                                                                              └──no_tool_calls──▶ :idle
```

| State | Description | Allowed transitions |
|-------|-------------|-------------------|
| `:idle` | Waiting for user input. | → `:calling` (on prompt) |
| `:calling` | Sending request to LLM provider. Waiting for first stream event. | → `:streaming` (on first chunk), → `:idle` (on error after retries) |
| `:streaming` | Receiving streaming response. Accumulating text and tool calls. | → `:executing_tools` (on stream end), → `:idle` (on abort/error) |
| `:executing_tools` | Running tool calls. Collecting results. | → `:calling` (tool results need LLM continuation), → `:idle` (no tool calls or final response) |

**Behaviors:**

- **Prompt queueing.** If a prompt arrives while not `:idle`, it is queued. Delivered after the current turn completes.
- **Abort.** User can abort at any time. In `:streaming`, cancel the stream via `cancel_stream/1`. In `:executing_tools`, terminate all in-flight tasks. Transition to `:idle`.
- **Turn limit.** Configurable max consecutive LLM calls per prompt (default: 25). When reached, pause and ask "Continue?" If yes, reset counter. If no, return to `:idle`.
- **Error recovery.** On provider error, retry with exponential backoff up to 3 times. If all fail, transition to `:idle` and surface error.
- **Event broadcasting.** Agent broadcasts state transitions and content events via Registry for TUI consumption.

### 3. Message Format

The canonical internal message format used across all layers:

```
Deft.Message
  id        :: String.t()
  role      :: :system | :user | :assistant
  content   :: [ContentBlock.t()]
  timestamp :: DateTime.t()

ContentBlock (union type):
  Deft.Message.Text       :: %{text: String.t()}
  Deft.Message.ToolUse    :: %{id: String.t(), name: String.t(), args: map()}
  Deft.Message.ToolResult :: %{tool_use_id: String.t(), name: String.t(), content: String.t(), is_error: boolean()}
  Deft.Message.Thinking   :: %{text: String.t()}
  Deft.Message.Image      :: %{media_type: String.t(), data: String.t()}
```

Providers convert from this format to wire format. Session persistence serializes as JSON. The OM system reads content blocks to format messages for the Observer.

### 4. Context Assembly

On each turn, the context is assembled in this order:
1. **System prompt** — role definition, tool descriptions, working directory, date/environment, project instructions, conflict resolution rules
2. **Observation injection** — if OM is active, observations as a system message
3. **Conversation history** — messages from the current session, minus observed-and-trimmed messages
4. **Project context** — `DEFT.md`, `CLAUDE.md`, or `AGENTS.md` from working directory

### 5. Token Tracking

The agent tracks:
- `total_input_tokens` / `total_output_tokens` — cumulative across all turns
- `current_context_tokens` — estimated tokens in current message list
- `context_window` — model's context window size
- `session_cost` — cumulative estimated cost

Updated after each LLM response from `:usage` events.

**Compaction fallback** (when OM is disabled): if `current_context_tokens > 0.7 * context_window`, summarize oldest messages and replace with a single summary message. Disabled when OM is active.

## Notes

### Design decisions

- **gen_statem with `handle_event` mode.** Allows fallback handlers in any state (critical for abort, which must work in all states).
- **JSONL over SQLite for sessions.** Append-only, human-readable, linearly reconstructed.
- **Provider events via process messages.** Simple `receive` in gen_statem, no callback complexity.
- **Compaction at 70%.** Leaves room for model response. 80% was too aggressive per reviewer feedback.

## References

- [tools.md](tools.md) — tool system
- [providers.md](providers.md) — LLM provider layer
- [sessions.md](sessions.md) — persistence, config, CLI
- [tui.md](tui.md) — terminal UI
- [observational-memory.md](observational-memory.md) — OM system
- [orchestration.md](orchestration.md) — Foreman/Lead/Runner
- [standards.md](standards.md) — coding standards
