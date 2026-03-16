# Providers

| | |
|--------|----------------------------------------------|
| Version | 0.1 |
| Status | Ready |
| Last Updated | 2026-03-16 |

## Changelog

### v0.1 (2026-03-16)
- Initial spec — extracted from harness spec. Provider behaviour, event types, SSE streaming, Anthropic implementation.

## Overview

The provider layer abstracts LLM API differences behind a common behaviour. The agent loop has no knowledge of specific providers — all provider specifics live behind callbacks. This allows adding new providers (OpenAI, Google) by implementing the behaviour without changing the agent loop.

**Scope:**
- Provider behaviour definition
- Common event type normalization
- SSE streaming and parsing
- Stream lifecycle (creation, monitoring, cancellation)
- Anthropic Messages API implementation
- Model configuration (context windows, pricing)

**Out of scope:**
- Agent loop that consumes provider events (see [harness.md](harness.md))
- Rate limiting (see [orchestration.md](orchestration.md) for job-level rate limiting)

**Dependencies:**
- [standards.md](standards.md) — coding standards
- [harness.md](harness.md) — message format (`Deft.Message` structs that providers convert to wire format)

## Specification

### 1. Provider Behaviour

Each provider implements the `Deft.Provider` behaviour:

```
callback stream(messages, tools, config) :: {:ok, stream_ref} | {:error, term()}
callback cancel_stream(stream_ref) :: :ok
callback parse_event(raw_event) :: provider_event()
callback format_messages(messages) :: provider_messages()
callback format_tools(tools) :: provider_tools()
callback model_config(model_name) :: %{context_window: integer(), max_output: integer(), input_price_per_mtok: float(), output_price_per_mtok: float()}
```

**Stream lifecycle:**
- `stream/3` initiates a streaming HTTP request. Returns a `stream_ref` (opaque reference).
- The provider sends parsed events to the caller's mailbox as `{:provider_event, event}` messages.
- The Agent monitors the stream process — if it dies unexpectedly, the Agent handles the `:DOWN` message (transitions to `:idle` or retries).
- `cancel_stream/1` cleanly terminates an in-flight stream (used on abort). Closes the HTTP connection.

### 2. Event Types

Providers normalize their streaming events into a common format:

| Event | Payload | Description |
|-------|---------|-------------|
| `:text_delta` | `%{delta: String.t()}` | Incremental text chunk |
| `:thinking_delta` | `%{delta: String.t()}` | Thinking/reasoning chunk |
| `:tool_call_start` | `%{id: String.t(), name: String.t()}` | Beginning of a tool call |
| `:tool_call_delta` | `%{id: String.t(), delta: String.t()}` | Incremental tool call arguments (JSON fragment) |
| `:tool_call_done` | `%{id: String.t(), args: map()}` | Complete tool call with parsed args |
| `:usage` | `%{input: integer(), output: integer()}` | Token usage report |
| `:done` | `%{}` | Stream complete |
| `:error` | `%{message: String.t()}` | Provider error |

### 3. SSE Parsing

Raw HTTP response chunks are parsed using the `server_sent_events` library before being passed to the provider's `parse_event/1` callback. The SSE parser handles:
- Buffering partial lines across TCP chunk boundaries
- Parsing `event:` and `data:` fields
- Multi-line `data:` fields
- Reconnection on connection drops

### 4. Anthropic Provider

The first provider targets the Anthropic Messages API (`https://api.anthropic.com/v1/messages`).

**Authentication:** `ANTHROPIC_API_KEY` from environment. Fail fast on startup if missing.

**Request format:** POST with `stream: true`. System message extracted to top-level `system` param. User/assistant messages with content arrays. Tool_use and tool_result content blocks.

**SSE event mapping:**
| Anthropic event | Deft event |
|----------------|------------|
| `content_block_start` (type: text) | `:text_delta` (first chunk) |
| `content_block_delta` (type: text_delta) | `:text_delta` |
| `content_block_start` (type: tool_use) | `:tool_call_start` |
| `content_block_delta` (type: input_json_delta) | `:tool_call_delta` |
| `content_block_stop` (for tool_use) | `:tool_call_done` |
| `content_block_start` (type: thinking) | `:thinking_delta` (first chunk) |
| `content_block_delta` (type: thinking_delta) | `:thinking_delta` |
| `message_delta` | `:usage` (from `usage` field) |
| `message_stop` | `:done` |
| error event | `:error` |

**Models and config:**
| Model | Context window | Max output | Input $/MTok | Output $/MTok |
|-------|---------------|-----------|-------------|--------------|
| claude-sonnet-4 | 200,000 | 16,000 | $3.00 | $15.00 |
| claude-opus-4 | 200,000 | 32,000 | $15.00 | $75.00 |
| claude-haiku-4.5 | 200,000 | 8,192 | $0.80 | $4.00 |

**Extended thinking:** Supported via `thinking` content blocks. Enabled when the model config includes `thinking: true`.

## Notes

### Design decisions

- **Events via process messages, not callbacks.** The provider sends `{:provider_event, event}` to the caller's mailbox. This keeps the gen_statem agent loop simple — it handles events in `handle_event`, not in callbacks from another process.
- **`server_sent_events` library over hand-rolled SSE parser.** SSE has edge cases (partial lines across chunks, multi-line data fields) that the library handles correctly. ~50 lines to hand-roll but easy to get wrong.

### Open questions

- **Stall detection.** If no chunks arrive for N seconds, should the provider emit a warning event? Useful for detecting hung connections.

## References

- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- [server_sent_events (Hex)](https://hex.pm/packages/server_sent_events)
- [harness.md](harness.md) — agent loop
