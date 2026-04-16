# Tools

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Implemented |
| Last Updated | 2026-03-29 |

## Changelog

### v0.3 (2026-03-29)
- Added orchestration tools — tools whose `execute/2` sends a message to a parent process and returns a confirmation. Enabled by optional `parent_pid` field in `ToolContext`.
- Added `cache_config` field to `ToolContext` (was implicit, now documented)

### v0.2 (2026-03-19)
- Clarified edit tool: unified diff must use a real diff algorithm (LCS or Myers), not positional line comparison
- Clarified find tool: `fd` exit code 1 must be treated as an error on fd v8+, not as "no results"

### v0.1 (2026-03-16)
- Initial spec — extracted from harness spec. Tool behaviour, 7 built-in tools, tool execution model.

## Overview

The tool system defines how Deft's agent interacts with the filesystem, shell, and codebase. Every tool implements a common behaviour and is executed in isolated, supervised Tasks that cannot crash the agent.

**Scope:**
- Tool behaviour definition
- 7 built-in tools: read, write, edit, bash, grep, find, ls
- Tool execution model (concurrent, supervised, timeout-enforced)
- ToolContext (working directory, session ID, emit function, file scope)

**Out of scope:**
- Agent loop that dispatches tool calls (see [harness.md](harness.md))
- Web search / fetch tools (future)
- MCP tool integration (future)

**Dependencies:**
- [standards.md](standards.md) — coding standards and project structure
- [harness.md](harness.md) — message format (ContentBlock types used in tool return values)

## Specification

### 1. Tool Behaviour

Every tool implements the `Deft.Tool` behaviour:

```
callback name() :: String.t()
callback description() :: String.t()
callback parameters() :: json_schema()
callback execute(args :: map(), context :: ToolContext.t()) :: {:ok, [ContentBlock.t()]} | {:error, String.t()}
```

`ToolContext` provides:
- `working_dir` — the directory the session is operating in
- `session_id` — current session identifier
- `emit` — function for streaming incremental output back to the TUI during long-running tools (e.g., bash output)
- `file_scope :: [String.t()] | nil` — optional restriction on write/edit paths (used by orchestration; `nil` means unrestricted)
- `parent_pid :: pid() | nil` — optional PID of the orchestrator process that owns this agent. Used by orchestration tools to send messages back to their orchestrator. `nil` for standalone sessions.
- `cache_config :: %{optional(String.t()) => pos_integer()} | nil` — per-tool spilling thresholds (see [filesystem.md](filesystem.md))

Tools return a list of content blocks (typically a single `Text` block, but structured content for future MCP compatibility). The agent loop wraps these into `ToolResult` messages for the LLM.

### 1.1 Orchestration Tools

Orchestration tools are tools whose primary effect is sending a message to the agent's parent orchestrator process. They follow the same `Deft.Tool` behaviour but use `context.parent_pid` to communicate with the orchestrator.

Pattern:
1. Tool validates args
2. Tool calls `GenServer.cast(context.parent_pid, {:agent_action, action, payload})`
3. Tool returns `{:ok, [Text.new("action requested")]}`

The agent sees a normal tool result. The orchestrator receives the message in `handle_event(:cast, ...)`. This keeps agents standard — they don't know they're being orchestrated, they just have extra tools available.

Orchestration tools are defined by the orchestration layer (see [orchestration](orchestration/README.md)), not in this spec. This spec only defines the mechanism (`parent_pid` in ToolContext).

### 2. Built-in Tools

Seven built-in tools, matching the standard coding agent toolset:

| Tool | Purpose | Key behaviors |
|------|---------|--------------|
| `read` | Read file contents | Supports line offset/limit for pagination. Returns content with line numbers. Reads images as base64. |
| `write` | Create or overwrite files | Creates parent directories if needed. Returns confirmation with byte count. |
| `edit` | String replacement in files | Two modes: (1) **string match** — requires unique match of old_string, returns unified diff, fails if not found or not unique; (2) **line-range** — accepts start_line, end_line, new_content, replaces that range. Error messages include nearby similar text when exact match fails. |
| `bash` | Execute shell commands | Streams stdout/stderr to TUI via `emit`. Configurable timeout (default 120s). Truncates output to last 100 lines or 30KB, saves full output to temp file. |
| `grep` | Search file contents | Uses ripgrep (`rg`) under the hood. Supports regex, glob filtering, case-insensitive, context lines. Respects `.gitignore`. Caps at 100 matches. Falls back to Elixir-native `:re` + `File.stream` if `rg` is not installed. |
| `find` | Find files by name/pattern | Uses `fd` under the hood. Glob patterns. Respects `.gitignore`. Caps at 1000 results. Falls back to `Path.wildcard` if `fd` is not installed. |
| `ls` | List directory contents | Returns formatted directory listing with file types and sizes. |

### 3. Tool Execution

- All tool calls from a single LLM turn are executed concurrently via `Task.Supervisor.async_nolink` under `Deft.Agent.ToolRunner`.
- Each task runs with a timeout (configurable, default from `tool_timeout` config). If a task exceeds its timeout, it is killed and an error result is returned.
- Exceptions in tool execution are caught and converted to error strings — they never propagate to the agent process.
- Tool results are collected via `Task.yield_many/2` and sent back to the LLM as tool_result messages in the next turn.

### 4. File Scope Enforcement

When `file_scope` is set in ToolContext (by the orchestration system), `write` and `edit` tools check the target path against the scope before executing. Writes to paths outside the scope return `{:error, "path outside file scope"}`.

Note: `bash` cannot be statically scoped — shell commands can modify any file. When file scope is active, this is a known gap. The orchestration system mitigates this via worktree isolation (each Lead works in its own git worktree).

## Notes

### Open questions

- **Fuzzy match fallback for edit.** When exact string match fails, should the edit tool try `String.jaro_distance/2` to find the closest match and present it for confirmation? This would save a tool round-trip on whitespace mismatches.

## References

- [harness.md](harness.md) — agent loop and message format
- [standards.md](standards.md) — coding standards
