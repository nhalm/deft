# TUI

| | |
|--------|----------------------------------------------|
| Version | 0.2 |
| Status | Ready |
| Last Updated | 2026-03-19 |

## Changelog

### v0.2 (2026-03-19)
- Clarified slash command dispatch: must handle all error variants from `SlashCommand.dispatch/1`, including I/O errors
- Clarified markdown rendering: link nodes without `href` attribute must not crash

### v0.1 (2026-03-16)
- Initial spec — extracted from harness spec. Breeze views, rendering, input handling, slash commands, status bar.

## Overview

The TUI (Terminal User Interface) is Deft's primary user interface. Built on the Breeze framework (LiveView-style terminal rendering), it provides a chat interface with streaming LLM output, tool execution display, and an always-visible status bar.

**Scope:**
- Chat view (streaming conversation, tool display)
- Session picker view
- Status bar
- Input handling (multi-line, keyboard shortcuts)
- Slash command dispatch
- Markdown-to-ANSI rendering
- Streaming text rendering
- Job status display (orchestration mode)

**Out of scope:**
- Agent loop logic (see [harness.md](harness.md))
- Slash command implementations (each spec owns its commands; TUI just dispatches)

**Dependencies:**
- [standards.md](standards.md) — coding standards
- [harness.md](harness.md) — agent events that the TUI subscribes to
- [observational-memory.md](observational-memory.md) — OM events for status display

## Specification

### 1. Framework

Built on Breeze (LiveView-style TUI). `mount/2`, `render/1`, `handle_event/3`, `handle_info/2` with `~H` HEEx templates.

**Risk mitigation:** Build a streaming proof-of-concept before committing: 1000+ lines of mixed text, 30 tokens/sec append rate, scrollable area + fixed input + status bar. If Breeze cannot handle this, fall back to Termite + BackBreeze directly.

### 2. Chat View (Default)

```
┌─ Deft ───────────────────────────── model: claude-sonnet-4 ─┐
│                                                              │
│  [scrollable conversation area]                              │
│                                                              │
│  User: explain the auth module                               │
│                                                              │
│  Assistant: The auth module handles...                       │
│  ▊ (streaming cursor)                                        │
│                                                              │
│  [Tool: read] src/auth.ex ✓                                  │
│  [Tool: bash] mix test ✓ (3.2s)                              │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ > user input area                                            │
├──────────────────────────────────────────────────────────────┤
│ 12.4k/200k │ memory: --  │ $0.12 │ turn 2/25 │ ◉ idle      │
└──────────────────────────────────────────────────────────────┘
```

### 3. Rendering

- **Streaming text.** LLM output renders token-by-token as it arrives via `handle_info` for `:text_delta` events. Appends to current assistant message in assigns.
- **Markdown rendering.** Parse with Earmark, render to ANSI escape codes via custom renderer. Bold, italic, inline code, fenced code blocks (with language label), bullet/numbered lists. Streaming partial markdown: buffer the last incomplete line; only render complete blocks.
- **Tool execution display.** Each tool call: tool name + key argument, spinner while running, ✓/✗ + duration on completion.
- **Scrollback.** Conversation area is scrollable. User can scroll up while agent continues.

### 4. Status Bar

Always visible. Shows:

| Field | Example | Source |
|-------|---------|--------|
| Token usage | `12.4k/200k` | current context / context window |
| Memory | `memory: 3.2k/40k` or `memory: --` (before first observation) | OM observation tokens / reflection threshold |
| Cost | `$0.42` | cumulative session cost |
| Turn count | `turn 3/25` | current / limit |
| Agent state | `◉ idle` | gen_statem state |

During orchestrated jobs, the status bar shows job-level info:
```
│ 2 leads │ 1/2 complete │ $1.24/$10 │ 4m elapsed │ ◉ executing │
```

OM activity indicator: show spinner when observation or reflection is in progress. Show `memorizing...` during sync fallback.

### 5. Input Handling

- **Enter** — submit prompt
- **Multi-line:** Shift+Enter (Kitty protocol), `\` + Enter (fallback), paste detection (chars within 5ms = literal newlines)
- **Up/Down** — recall input history when in input area
- **Page Up/Down** — scroll conversation
- **Ctrl+C** — abort current operation / exit if idle
- **Ctrl+D** — exit (standard Unix EOF)
- **Ctrl+L** — clear screen
- **Ctrl+R** — toggle raw output (no markdown rendering)
- **Esc** — cancel current input / abort

### 6. Slash Commands

Recognized by leading `/` in input. Dispatched before prompt reaches agent loop.

| Command | Description | Spec owner |
|---------|-------------|-----------|
| `/help` | Show available commands and shortcuts | TUI |
| `/model <name>` | Switch model | sessions |
| `/clear` | Clear display | TUI |
| `/compact` | Force compaction | harness |
| `/observations` | Show OM observations (--full, --search) | observational-memory |
| `/forget <text>` | Mark observation for removal | observational-memory |
| `/correct <old> -> <new>` | Mark observation for correction (also accepts `→`) | observational-memory |
| `/cost` | Show cost breakdown | sessions |
| `/status` | Show job status | orchestration |
| `/inspect <lead>` | Show Lead's Site Log entries (--last N, --type) | orchestration |
| `/plan` | Re-display approved plan | orchestration |
| `/quit` | Exit | TUI |

### 7. Session Picker View

Lists sessions from `Deft.Session.Store.list/0`. Shows: session ID, working_dir, last timestamp, message count. Arrow keys to navigate, Enter to select and resume.

## Notes

### Open questions

- **Alt screen vs scrollback.** Breeze likely uses alt screen (box model). Coding agent users prefer scrollback (native Cmd+F, text selection). Need to verify and decide.
- **Markdown-to-ANSI.** No Elixir library exists. Options: Earmark AST → custom renderer, or MDEx (Rust NIF via comrak). Streaming partial markdown needs buffering.
- **Terminal compatibility.** Test on: iTerm2, Terminal.app, WezTerm/Kitty, GNOME Terminal/Alacritty. Graceful degradation for terminals without 24-bit color or extended keyboard protocols.

## References

- [Breeze](https://github.com/Gazler/breeze)
- [Earmark](https://github.com/pragdave/earmark)
- [Termite](https://github.com/Gazler/termite)
