# Sessions

| | |
|--------|----------------------------------------------|
| Version | 0.7 |
| Status | Ready |
| Last Updated | 2026-03-29 |

## Changelog

### v0.7 (2026-03-29)
- Clarified distinction between user sessions and agent sessions. User sessions are conversations; agent sessions are internal LLM state for orchestrated sub-agents (ForemanAgent, LeadAgents). Same JSONL format, different storage paths.

### v0.6 (2026-03-24)
- Replaced escript with unified CLI dispatcher — same `./deft` binary handles all subcommands
- Application always starts full supervision tree (including Endpoint); CLI dispatcher controls what runs
- All subcommands work in both dev (`mix deft <subcommand>`) and release (`./deft <subcommand>`)
- Added Bandit adapter config, prod.exs, dynamic port selection, browser auto-open, pidfile

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

There are two kinds of sessions, both using the same JSONL format:

**User sessions** — conversations between the user and Deft. These are the primary sessions.
- Storage: `~/.deft/projects/<path-encoded-repo>/sessions/<session_id>.jsonl`
- Listed in the web UI session picker. Resumable by the user.

**Agent sessions** — internal LLM conversation history for orchestrated sub-agents (ForemanAgent, LeadAgents). These are not user-facing.
- Storage: `~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/foreman_session.jsonl` and `lead_<id>_session.jsonl`
- Not listed in the session picker. Not directly resumable — the orchestrator starts fresh agents on job resume (see [orchestration.md](orchestration.md)).
- Same entry types, same format. The only difference is storage path and lifecycle.

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

### 5. Application Runtime

Deft is a Phoenix web application with CLI subcommands. The OTP application always starts the full supervision tree (agent subsystems, Phoenix endpoint, PubSub). A CLI dispatcher controls what happens after startup.

#### 5.1 Architecture

```
Deft.Application.start/2
  └── Supervision tree (always starts fully):
      ├── Deft.Registry (duplicate — event pub/sub)
      ├── Deft.ProcessRegistry (unique — process naming)
      ├── Deft.Provider.Registry
      ├── Deft.Skills.Registry
      ├── Deft.Session.Supervisor
      ├── Phoenix.PubSub (name: Deft.PubSub)
      ├── DeftWeb.Endpoint (Bandit on localhost:<port>)
      └── (optional) Deft.Issues

After the supervision tree starts, Deft.CLI.main/1 dispatches based on argv.
```

The endpoint always starts. It's cheap (~2MB idle) and means the web UI is always available, even during `deft work` — you can open the browser to monitor a running job.

#### 5.2 CLI Dispatcher

`Deft.CLI.main/1` parses `System.argv()` and dispatches:

| Command | Action |
|---------|--------|
| `deft` (no args) | Open browser to web UI, block until Ctrl+C |
| `deft -p "prompt"` | Non-interactive: send prompt, stream response to stdout, exit |
| `deft work` | Pick highest-priority ready issue, run as job (see [issues.md](issues.md)) |
| `deft work --loop` | Keep picking issues until queue empty or cost ceiling |
| `deft work <id>` | Run a specific issue as a job |
| `deft issue create <title>` | Interactive issue creation session |
| `deft issue list` | List issues |
| `deft issue show <id>` | Show issue details |
| `deft issue ready` | List ready (unblocked) issues |
| `deft issue update <id>` | Update issue fields |
| `deft issue close <id>` | Close an issue |
| `deft config` | Show current configuration |
| `deft --help` | Show help |
| `deft --version` | Show version |

All commands work identically in dev and release. The dispatcher is the same `Deft.CLI` module used today — it just no longer runs as an escript.

#### 5.3 Development

```
mix phx.server                    # web UI only (standard Phoenix)
iex -S mix phx.server             # web UI + IEx shell
mix run -e "Deft.CLI.main([])"    # web UI via CLI dispatcher
mix run -e "Deft.CLI.main([\"work\", \"--loop\"])"  # work loop
```

Or via a Mix task wrapper (convenience):

```
mix deft                          # web UI
mix deft work --loop              # work loop
mix deft -p "prompt"              # non-interactive
mix deft issue list               # issue commands
```

The `Mix.Tasks.Deft` task delegates to `Deft.CLI.main/1` after ensuring the application is started.

#### 5.4 Flags

| Flag | Description |
|------|-------------|
| `--model <name>` | Override model |
| `--provider <name>` | Override provider |
| `--no-om` | Disable observational memory |
| `--working-dir <path>` | Override working directory |
| `-p <prompt>` | Non-interactive single-turn mode |
| `--output <file>` | Write response to file (non-interactive) |
| `--auto-approve-all` | Skip all plan approvals for orchestrated jobs |
| `--help` / `-h` | Show help |
| `--version` | Show version |

#### 5.5 Interactive Mode (Web UI)

When `deft` is invoked with no subcommand (or in the release binary with no args):

1. Application starts (supervision tree including Endpoint)
2. CLI opens the browser: `System.cmd("open", [url])` on macOS, `xdg-open` on Linux
3. Prints `Deft running at http://localhost:<port>` to terminal
4. Blocks with `Process.sleep(:infinity)` until Ctrl+C

Session management (new, resume, picker) is handled entirely by the web UI routes.

#### 5.6 Non-Interactive Mode

`deft -p "prompt"` sends a single prompt, streams the response to stdout, and exits. The endpoint is running but unused. Output goes to stdout or `--output <file>`.

### 6. Distribution

#### 6.1 Mix Release + Burrito

Packaged as a Mix release wrapped with Burrito for single-binary distribution.

```
MIX_ENV=prod mix assets.deploy   # build CSS/JS
MIX_ENV=prod mix release         # build release + Burrito binary
```

The release includes:
- BEAM runtime (via Burrito — no Erlang/Elixir install needed)
- `priv/static/` with compiled CSS, JS, and Phoenix assets
- Config (compiled from config/*.exs)
- All application code

#### 6.2 Release Binary

The Burrito binary is invoked as `./deft`. It starts the OTP application, then runs `Deft.CLI.main(argv)` to dispatch subcommands.

```
./deft                           # web UI — opens browser
./deft work --loop               # work loop
./deft -p "prompt"               # non-interactive
./deft issue list                # issue commands
```

All the same commands as dev mode. No `eval` or wrapper scripts needed — the release binary IS the CLI.

#### 6.3 Release Configuration

The release binary needs:

- `config/runtime.exs` — reads `PORT`, `ANTHROPIC_API_KEY`, `SECRET_KEY_BASE` from env. Generates `SECRET_KEY_BASE` if not set (local tool, not a web service).
- `config/prod.exs` — `server: true` (starts HTTP listener), Bandit adapter config.
- Dynamic port selection: try `PORT` env, then 4000, then 4001-4099 if busy. Write actual port to `~/.deft/projects/<path-encoded-repo>/server.pid`.

#### 6.4 Targets

- macOS (arm64, x86_64)
- Linux (x86_64, aarch64)

External runtime dependencies: `rg` (ripgrep) and `fd` (fd-find) — warn on startup if missing.

Startup orphan cleanup: scan for `deft/job-*` branches and worktrees from crashed jobs, offer to clean up.

**No escript.** Escript doesn't support `priv/` directories, signal handling is broken on OTP 28, and it conflicts with Phoenix's runtime model.

## References

- [harness.md](harness.md) — agent loop
- [web-ui.md](web-ui.md) — web interface
- [issues.md](issues.md) — issue tracker, work mode
- [standards.md](standards.md) — coding standards
