# Sessions

| | |
|--------|----------------------------------------------|
| Version | 0.9 |
| Status | Ready |
| Last Updated | 2026-04-10 |

## Changelog

### v0.9 (2026-04-10)
- Unified entry point: every session starts a Foreman. `Session.Worker` starts the Foreman subtree, not a standalone `Deft.Agent`. See [orchestration/README.md](../orchestration/README.md).
- `deft work` is now just a session with an issue as the first prompt — no separate `Job.Supervisor`.

### v0.8 (2026-04-10)
- Restructured into sub-specs: persistence, context, runtime, branching
- Existing content extracted without behavioral changes
- Added branching spec (Draft) — user-initiated session forking with git state restore

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

Sessions handle persistence, configuration, and the CLI entry point for Deft. A session is the unit of conversation — it has an ID, a working directory, a conversation history, and optional OM state. Every session starts a Foreman (see [orchestration](../orchestration/README.md)). Sessions are stored as JSONL files and can be resumed. Users can branch from any checkpoint to fork a session and try a different approach.

**Scope:**
- Session persistence (JSONL storage format, entry types)
- Session resume, listing, and branching
- Configuration loading (YAML, priority cascade)
- CLI interface (commands, flags, non-interactive mode)
- System prompt assembly and context management
- Single-binary distribution (Burrito)

**Out of scope:**
- Agent loop mechanics (see [../harness.md](../harness.md))
- Web UI rendering (see [../web-ui.md](../web-ui.md))

**Dependencies:**
- [../standards.md](../standards.md) — coding standards, project structure
- [../harness.md](../harness.md) — message format, agent loop
- [../git-strategy.md](../git-strategy.md) — git worktree and branch management (used by branching)

## Included Specs

| Spec | Version | Status | Description |
|------|---------|--------|-------------|
| [persistence](persistence.md) | v0.8 | Implemented | JSONL storage format, entry types, storage paths, resume, listing, checkpoint entries |
| [context](context.md) | v0.8 | Implemented | System prompt assembly, message list construction, token tracking, compaction, cost tracking |
| [runtime](runtime.md) | v0.8 | Implemented | Configuration, CLI dispatcher, Phoenix application, distribution |
| [branching](branching.md) | v0.1 | Draft | User-initiated session forking from checkpoints with git state restore |

## References

- [../harness.md](../harness.md) — agent loop
- [../web-ui.md](../web-ui.md) — web interface
- [../issues.md](../issues.md) — issue tracker, work mode
- [../standards.md](../standards.md) — coding standards
- [../git-strategy.md](../git-strategy.md) — git worktree strategy
