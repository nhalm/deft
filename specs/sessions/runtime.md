# Session Runtime

| | |
|--------|----------------------------------------------|
| Version | 0.9 |
| Status | Ready |
| Last Updated | 2026-04-13 |

## Changelog

### v0.9 (2026-04-13)
- Audit demoted to Ready: `ANTHROPIC_API_KEY` fail-fast (§1.2) is not enforced at startup, and `deft` with no args (§2.5) does not auto-open the browser via `System.cmd("open"/"xdg-open", ...)`.

### v0.8 (2026-04-10)
- Extracted from sessions.md §2, §5-6 into standalone sub-spec

## Overview

Session runtime covers configuration loading, the CLI dispatcher, the Phoenix application architecture, and single-binary distribution. This is the "how Deft starts and runs" spec.

**Scope:**
- Configuration sources and fields
- CLI dispatcher (commands, flags)
- Phoenix application supervision tree
- Development and release modes
- Distribution (Mix release + Burrito)

**Out of scope:**
- Session persistence format (see [persistence.md](persistence.md))
- Context assembly (see [context.md](context.md))
- Web UI rendering (see [../web-ui.md](../web-ui.md))

**Dependencies:**
- [../standards.md](../standards.md) — coding standards, project structure
- [../issues.md](../issues.md) — issue commands, work mode

## Specification

### 1. Configuration

#### 1.1 Configuration Sources (in priority order)

1. **CLI flags** — `--model`, `--provider`, `--working-dir`
2. **Project config** — `.deft/config.yaml` in the working directory
3. **User config** — `~/.deft/config.yaml`
4. **Defaults**

#### 1.2 Configuration Fields

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

### 2. Application Runtime

Deft is a Phoenix web application with CLI subcommands. The OTP application always starts the full supervision tree (agent subsystems, Phoenix endpoint, PubSub). A CLI dispatcher controls what happens after startup.

#### 2.1 Architecture

```
Deft.Application.start/2
  +-- Supervision tree (always starts fully):
      |-- Deft.Registry (duplicate -- event pub/sub)
      |-- Deft.ProcessRegistry (unique -- process naming)
      |-- Deft.Provider.Registry
      |-- Deft.Skills.Registry
      |-- Deft.Session.Supervisor
      |-- Phoenix.PubSub (name: Deft.PubSub)
      |-- DeftWeb.Endpoint (Bandit on 0.0.0.0:<port>)
      +-- (optional) Deft.Issues

After the supervision tree starts, Deft.CLI.main/1 dispatches based on argv.
```

The endpoint always starts. It's cheap (~2MB idle) and means the web UI is always available, even during `deft work` — you can open the browser to monitor a running job.

#### 2.2 CLI Dispatcher

`Deft.CLI.main/1` parses `System.argv()` and dispatches:

| Command | Action |
|---------|--------|
| `deft` (no args) | Open browser to web UI, block until Ctrl+C |
| `deft -p "prompt"` | Non-interactive: send prompt, stream response to stdout, exit |
| `deft work` | Pick highest-priority ready issue, run as job (see [../issues.md](../issues.md)) |
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

All commands work identically in dev and release. The dispatcher is the same `Deft.CLI` module — it just no longer runs as an escript.

#### 2.3 Development

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

#### 2.4 Flags

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

#### 2.5 Interactive Mode (Web UI)

When `deft` is invoked with no subcommand (or in the release binary with no args):

1. Application starts (supervision tree including Endpoint)
2. CLI opens the browser: `System.cmd("open", [url])` on macOS, `xdg-open` on Linux
3. Prints `Deft running at http://localhost:<port>` to terminal
4. Blocks with `Process.sleep(:infinity)` until Ctrl+C

Session management (new, resume, picker) is handled entirely by the web UI routes.

#### 2.6 Non-Interactive Mode

`deft -p "prompt"` sends a single prompt, streams the response to stdout, and exits. The endpoint is running but unused. Output goes to stdout or `--output <file>`.

### 3. Distribution

#### 3.1 Mix Release + Burrito

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

#### 3.2 Release Binary

The Burrito binary is invoked as `./deft`. It starts the OTP application, then runs `Deft.CLI.main(argv)` to dispatch subcommands.

```
./deft                           # web UI -- opens browser
./deft work --loop               # work loop
./deft -p "prompt"               # non-interactive
./deft issue list                # issue commands
```

All the same commands as dev mode. No `eval` or wrapper scripts needed — the release binary IS the CLI.

#### 3.3 Release Configuration

The release binary needs:

- `config/runtime.exs` — reads `PORT`, `ANTHROPIC_API_KEY`, `SECRET_KEY_BASE` from env. Generates `SECRET_KEY_BASE` if not set (local tool, not a web service).
- `config/prod.exs` — `server: true` (starts HTTP listener), Bandit adapter config.
- Dynamic port selection: try `PORT` env, then 4000, then 4001-4099 if busy. Write actual port to `~/.deft/projects/<path-encoded-repo>/server.pid`.

#### 3.4 Targets

- macOS (arm64, x86_64)
- Linux (x86_64, aarch64)

External runtime dependencies: `rg` (ripgrep) and `fd` (fd-find) — warn on startup if missing.

Startup orphan cleanup: scan for `deft/job-*` branches and worktrees from crashed jobs, offer to clean up.

**No escript.** Escript doesn't support `priv/` directories, signal handling is broken on OTP 28, and it conflicts with Phoenix's runtime model.

## References

- [../standards.md](../standards.md) — coding standards
- [../issues.md](../issues.md) — issue tracker, work mode
- [../web-ui.md](../web-ui.md) — web interface
