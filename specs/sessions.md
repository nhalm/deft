# Sessions

| | |
|--------|----------------------------------------------|
| Version | 0.5 |
| Status | Ready |
| Last Updated | 2026-03-24 |

## Changelog

### v0.5 (2026-03-24)
- Replaced escript distribution with Mix release + Burrito
- Dev startup via `mix phx.server`, production via release binary
- Non-interactive mode via Mix task `mix deft.prompt` instead of `deft -p`
- CLI interface simplified — session/resume commands handled by web UI routes, not CLI arg parsing
- Added dynamic port selection (try 4000, increment if busy)

### v0.4 (2026-03-19)
- Clarified resume: must use observation entries from main JSONL as fallback when `_om.jsonl` snapshot is missing
- Clarified: `Store` must use `Deft.Project.sessions_dir/1` for project-scoped paths (not hardcoded `~/.deft/sessions/`)

### v0.3 (2026-03-17)
- Session storage path is now project-scoped: `~/.deft/projects/<path-encoded-repo>/sessions/<session_id>.jsonl`. See filesystem.md for the full directory layout.

### v0.2 (2026-03-16)
- Updated section 3: removed "Project instructions" from system prompt list. Project files are included in context assembly (section 4.1, item 4) as a separate message for better context management.

### v0.1 (2026-03-16)
- Initial spec — extracted from harness spec. Session persistence, resume, configuration, CLI interface, distribution.

## Overview

Sessions handle persistence, configuration, and the CLI entry point for Deft. A session is the unit of conversation — it has an ID, a working directory, a conversation history, and optional OM state. Sessions are stored as JSONL files and can be resumed.

**Scope:**
- Session persistence (JSONL storage format, entry types)
- Session resume and listing
- Configuration loading (YAML, priority cascade)
- CLI interface (commands, flags, non-interactive mode)
- System prompt assembly
- Single-binary distribution (Burrito)

**Out of scope:**
- Agent loop mechanics (see [harness.md](harness.md))
- TUI rendering (see [tui.md](tui.md))

**Dependencies:**
- [standards.md](standards.md) — coding standards, project structure
- [harness.md](harness.md) — message format, agent loop

## Specification

### 1. Session Persistence

#### 1.1 Storage Format

Sessions are stored as JSONL files. Each line is a JSON object representing one event in the session timeline.

Storage location: `~/.deft/projects/<path-encoded-repo>/sessions/<session_id>.jsonl`

Sessions are scoped per-project. The project is identified by the git repository root (resolved to a real path, no symlinks). The path is encoded by replacing `/` with `-` (e.g., `/Users/nick/myapp` → `-Users-nick-myapp`). See [filesystem.md](filesystem.md) for the full `~/.deft/projects/` layout.

#### 1.2 Entry Types

| Type | Description |
|------|-------------|
| `session_start` | Session metadata: ID, created_at, working_dir, model, config snapshot |
| `message` | A conversation message: role, content blocks, tool_calls, thinking, timestamp |
| `tool_result` | Tool execution result: tool_call_id, name, result, duration_ms, is_error |
| `model_change` | Model was changed mid-session |
| `observation` | OM state snapshot (see [observational-memory.md](observational-memory.md)) |
| `compaction` | Context was compacted: summary text, messages removed |
| `cost` | Cost checkpoint: cumulative session cost at this point |

#### 1.3 Session Resume

When resuming a session:
1. Read the JSONL file and reconstruct conversation state
2. Rebuild the message list from `message` and `tool_result` entries
3. Restore OM state from the latest `observation` entry
4. Display a summary of the previous conversation to the user

#### 1.4 Session Listing

Sessions are listed by most-recent-first. Each session shows: ID (short), working directory, last message timestamp, message count, and first line of the last user prompt.

### 2. Configuration

#### 2.1 Configuration Sources (in priority order)

1. **CLI flags** — `--model`, `--provider`, `--working-dir`
2. **Project config** — `.deft/config.yaml` in the working directory
3. **User config** — `~/.deft/config.yaml`
4. **Defaults**

#### 2.2 Configuration Fields

| Field | Default | Description |
|-------|---------|-------------|
| `model` | `"claude-sonnet-4"` | Default model name |
| `provider` | `"anthropic"` | Default provider |
| `turn_limit` | `25` | Max consecutive LLM calls per user prompt |
| `tool_timeout` | `120_000` | Default tool execution timeout (ms) |
| `bash_timeout` | `120_000` | Bash tool timeout (ms) |
| `om.enabled` | `true` | Enable observational memory |
| `om.observer_model` | `"claude-haiku-4.5"` | Model for Observer |
| `om.reflector_model` | `"claude-haiku-4.5"` | Model for Reflector |

Provider-specific configuration (API keys, base URLs) is read from environment variables:
- `ANTHROPIC_API_KEY` — Anthropic API key. Fail fast on startup if missing.
- `OPENAI_API_KEY` — OpenAI API key (future)
- `GOOGLE_API_KEY` — Google API key (future)

### 3. System Prompt

The system prompt is assembled dynamically and includes:
1. **Role definition** — "You are Deft, an AI coding agent..."
2. **Tool descriptions** — generated from registered tools' `name/0`, `description/0`, and `parameters/0` callbacks
3. **Working directory context** — current path, git branch if applicable
4. **Date and environment** — current date, OS, shell
5. **Conflict resolution** — "If observations conflict with current messages, messages take precedence. If observations conflict with project instructions, project instructions take precedence."

The system prompt does NOT include observation text — that is injected separately by the OM system. Project instructions are included in the context assembly as a separate message (see section 4.1, item 4).

### 4. Context Management

#### 4.1 Message List Assembly

On each turn, the context is assembled in this order:
1. **System prompt** — static instructions
2. **Observation injection** — if OM is active, observations as a system message (see [observational-memory.md](observational-memory.md))
3. **Conversation history** — messages from the current session, minus observed-and-trimmed messages
4. **Project context** — contents of `DEFT.md`, `CLAUDE.md`, or `AGENTS.md`

#### 4.2 Token Tracking

The agent tracks token usage from provider usage reports:
- `total_input_tokens` — cumulative input tokens across all turns
- `total_output_tokens` — cumulative output tokens across all turns
- `current_context_tokens` — estimated tokens in the current message list
- `context_window` — the model's context window size

When OM is not active, a compaction fallback exists: if `current_context_tokens > 0.7 * context_window`, oldest messages are summarized and replaced.

#### 4.3 Cost Tracking

Tracks estimated cost per model per turn from `:usage` events and model pricing:
- `session_cost` — cumulative estimated cost (Actor + OM calls)
- Displayed in TUI status bar, persisted in session JSONL

### 5. Startup Interface

Deft is a Phoenix web application. The primary interface is the browser.

#### 5.1 Development

```
mix phx.server        # start server, opens browser
iex -S mix phx.server # with interactive shell
```

The web UI handles session management — new sessions, resume, session picker are all browser routes (see [web-ui.md](web-ui.md)).

#### 5.2 Non-Interactive Mode (Mix Task)

| Usage | Description |
|-------|-------------|
| `mix deft.prompt "prompt"` | Single-turn: send prompt, print response, exit |
| `echo "prompt" \| mix deft.prompt` | Piped input: read from stdin |
| `mix deft.prompt "prompt" --output file.txt` | Write response to file |

In the release binary:
```
./bin/deft eval "Deft.CLI.run_prompt(\"prompt\")"
```

No web server is started for non-interactive mode. Output goes to stdout.

#### 5.3 Flags (Mix Task)

| Flag | Description |
|------|-------------|
| `--model <name>` | Override model |
| `--provider <name>` | Override provider |
| `--no-om` | Disable observational memory |
| `--working-dir <path>` | Override working directory |
| `--output <file>` | Write response to file |
| `--auto-approve-all` | Skip all plan approvals |

Interactive flags (session management, resume) are handled by the web UI, not the CLI.

### 6. Distribution

Packaged as a Mix release wrapped with Burrito for single-binary distribution.

- **Development:** `mix phx.server` — requires Elixir/Erlang installed
- **Production:** `mix release` produces a self-contained release with BEAM runtime, `priv/` assets, and config
- **Single binary:** Burrito wraps the release — `./deft` starts the Phoenix server and opens the browser
- Targets: macOS (arm64, x86_64), Linux (x86_64, aarch64)
- External runtime dependencies: `rg` (ripgrep) and `fd` (fd-find) — warn on startup if missing
- Startup orphan cleanup: scan for `deft/job-*` branches and worktrees from crashed jobs, offer to clean up

**No escript.** Escript doesn't support `priv/` directories (needed for static assets), signal handling is broken on OTP 28, and it conflicts with Phoenix's runtime model.

## References

- [harness.md](harness.md) — agent loop
- [web-ui.md](web-ui.md) — web interface
- [standards.md](standards.md) — coding standards
