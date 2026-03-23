# TUI

| | |
|--------|----------------------------------------------|
| Version | 0.4 |
| Status | Ready |
| Last Updated | 2026-03-23 |

## Changelog

### v0.4 (2026-03-23)
- Added TUI startup integration: CLI launches Breeze server for interactive mode, replacing stdio REPL
- Added Breeze lifecycle: startup, shutdown, clean terminal restore
- Added session picker integration via Breeze for `deft resume`
- Kept stdio REPL as fallback for non-interactive mode (unchanged)

### v0.3 (2026-03-23)
- Added thinking display: inline dimmed/italic rendering of `:thinking_delta` events
- Added agent identity: header shows current agent name and repo
- Added agent roster: persistent top-right panel showing all agents and their status during orchestration
- Redesigned header: now includes repo name, agent identity, and agent state

### v0.2 (2026-03-19)
- Clarified slash command dispatch: must handle all error variants from `SlashCommand.dispatch/1`, including I/O errors
- Clarified markdown rendering: link nodes without `href` attribute must not crash

### v0.1 (2026-03-16)
- Initial spec — extracted from harness spec. Breeze views, rendering, input handling, slash commands, status bar.

## Overview

The TUI (Terminal User Interface) is Deft's primary user interface. Built on the Breeze framework (LiveView-style terminal rendering), it provides a chat interface with streaming LLM output, tool execution display, and an always-visible status bar.

**Scope:**
- TUI startup and lifecycle (Breeze server integration with CLI)
- Chat view (streaming conversation, tool display)
- Session picker view
- Status bar
- Input handling (multi-line, keyboard shortcuts)
- Slash command dispatch
- Markdown-to-ANSI rendering
- Streaming text rendering
- Thinking display (inline reasoning visibility)
- Agent identity and roster display
- Job status display (orchestration mode)

**Out of scope:**
- Agent loop logic (see [harness.md](harness.md))
- Slash command implementations (each spec owns its commands; TUI just dispatches)
- Non-interactive mode (`deft -p`) — uses stdio, no TUI (see [sessions.md](sessions.md))

**Dependencies:**
- [standards.md](standards.md) — coding standards
- [harness.md](harness.md) — agent events that the TUI subscribes to
- [sessions.md](sessions.md) — CLI entry point, session creation, resume flow
- [observational-memory.md](observational-memory.md) — OM events for status display
- [providers.md](providers.md) — `:thinking_delta` events for thinking display
- [orchestration.md](orchestration.md) — Lead/Runner status for agent roster

## Specification

### 1. TUI Startup and Lifecycle

#### 1.1 Interactive Mode Startup

When the CLI starts an interactive session (`deft` or `deft resume`), it starts the Breeze server instead of the stdio REPL loop. The startup sequence:

1. CLI creates the session and starts the Agent (existing flow — session creation, provider registration, agent startup)
2. CLI starts Breeze: `Breeze.Server.start_link(view: Deft.TUI.Chat, params: %{session_id: session_id, agent_pid: agent_pid, config: config})`
3. Breeze takes over the terminal (alt screen) and mounts `Deft.TUI.Chat`
4. The CLI process blocks on the Breeze server (it runs until the view exits)

The existing `interactive_loop/1` stdio REPL is replaced by the Breeze server. Non-interactive mode (`deft -p`) is unchanged — it continues to use stdio.

#### 1.2 Resume Flow

When resuming a session (`deft resume`):
- **With session ID** (`deft resume <id>`): Reconstruct session state, start Agent, then start Breeze with `Deft.TUI.Chat` (same as new session, but with restored conversation)
- **Without session ID** (`deft resume`): Start Breeze with `Deft.TUI.SessionPicker`. When the user selects a session, the picker returns the selected session ID. The CLI then reconstructs that session and starts a new Breeze server with `Deft.TUI.Chat`.

#### 1.3 Shutdown

The TUI shuts down when:
- The user types `/quit` or presses Ctrl+D — the Breeze view returns `{:stop, term}`, Breeze restores the terminal, and the CLI exits cleanly
- The user presses Ctrl+C while idle — same as `/quit`
- The user presses Ctrl+C while agent is working — first press aborts the current operation (the view sends abort to the Agent and stays open), second press exits

On shutdown, Breeze restores the original terminal state (exits alt screen, restores cursor, re-enables line buffering). The CLI must ensure this happens even on crash — use a `try/after` block around the Breeze server to guarantee terminal restoration.

#### 1.4 Terminal Restoration on Crash

If the Breeze server or Agent crashes, the terminal must be restored to a usable state. The CLI wraps the Breeze server in:

```
try do
  Breeze.Server.start_link(view: view, params: params)
  Process.sleep(:infinity)
catch
  :exit, reason ->
    Breeze.Terminal.restore()  # or equivalent cleanup
    exit(reason)
end
```

If `Breeze.Terminal.restore/0` does not exist, emit raw ANSI reset sequences: `\e[?1049l` (exit alt screen), `\e[?25h` (show cursor), `\e[0m` (reset attributes).

### 2. Framework (unchanged from v0.1)

Built on Breeze (LiveView-style TUI). `mount/2`, `render/1`, `handle_event/3`, `handle_info/2` with `~H` HEEx templates.

**Risk mitigation:** Build a streaming proof-of-concept before committing: 1000+ lines of mixed text, 30 tokens/sec append rate, scrollable area + fixed input + status bar. If Breeze cannot handle this, fall back to Termite + BackBreeze directly.

### 3. Chat View (Default)

#### 3.1 Solo Mode

```
┌─ Deft ─ myapp ──────────────── model: claude-sonnet-4 ─ Solo ─┐
│                                                                 │
│  [thinking: analyzing the auth module structure                 │
│   and checking for dependency cycles...]                        │
│                                                                 │
│  User: explain the auth module                                  │
│                                                                 │
│  Assistant: The auth module handles...                          │
│  ▊ (streaming cursor)                                           │
│                                                                 │
│  [Tool: read] src/auth.ex ✓                                     │
│  [Tool: bash] mix test ✓ (3.2s)                                 │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ > user input area                                               │
├─────────────────────────────────────────────────────────────────┤
│ 12.4k/200k │ memory: --  │ $0.12 │ turn 2/25 │ ◉ idle          │
└─────────────────────────────────────────────────────────────────┘
```

In solo mode, the header shows the model name and "Solo" as the agent identity. No agent roster.

#### 3.2 Orchestration Mode

```
┌─ Deft ─ myapp ──────────────────────── Foreman ◉ executing ─┐
│                                        Lead A  ◉ implementing │
│  [thinking: evaluating Lead A's          Lead B  ◉ waiting     │
│   progress on the API layer...]          Runner  ◉ researching │
│                                                                │
│  User: build the auth system                                   │
│                                                                │
│  Foreman: I've decomposed this into two deliverables...        │
│  ▊ (streaming cursor)                                          │
│                                                                │
│  [Tool: read] src/auth.ex ✓                                    │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│ > user input area                                              │
├────────────────────────────────────────────────────────────────┤
│ 2 leads │ 1/2 complete │ $1.24/$10 │ 4m elapsed │ ◉ executing │
└────────────────────────────────────────────────────────────────┘
```

In orchestration mode:
- The header shows "Foreman" (the user always talks to the Foreman) and its current state.
- The **agent roster** appears in the top-right corner of the conversation area, right-aligned. It lists all active agents with their status.

### 4. Header

The header line contains, left to right:

| Element | Solo mode | Orchestration mode |
|---------|-----------|-------------------|
| App name | `Deft` | `Deft` |
| Repo name | basename of `working_dir` (e.g., `myapp`) | same |
| Model | `model: claude-sonnet-4` | (omitted — multiple models in play) |
| Agent identity | `Solo` | `Foreman` |
| Agent state | (shown in status bar) | `◉ <state>` |

The repo name is the basename of the session's `working_dir`. If `working_dir` is a git repository, use the repo root basename. Truncate to 20 characters if needed, with `…` suffix.

### 5. Agent Roster

The agent roster is a persistent overlay in the top-right of the conversation area. It only appears during orchestration (when a Job is active).

#### 5.1 Layout

Right-aligned text rows in the conversation area's top-right corner. Each row shows one agent:

```
Foreman  ◉ executing
Lead A   ◉ implementing
Lead B   ◉ waiting
Runner   ◉ researching
```

The roster occupies the rightmost ~30 columns. Conversation text wraps to avoid the roster area. If the terminal is too narrow (< 80 columns), the roster collapses to the header only (no inline roster).

#### 5.2 Agent Entries

| Agent type | Label | Shown when |
|------------|-------|------------|
| Foreman | `Foreman` | Always (during orchestration) |
| Lead | `Lead <id>` | While the Lead process is alive |
| Runner | `Runner` | While any Runner is active (shows count if >1: `Runners (3)`) |

#### 5.3 Agent States

| State | Display | Meaning |
|-------|---------|---------|
| Planning | `◉ planning` | Foreman: analyzing, decomposing |
| Researching | `◉ researching` | Running research Runners |
| Executing | `◉ executing` | Foreman: overseeing Leads |
| Implementing | `◉ implementing` | Lead: actively coding via Runners |
| Testing | `◉ testing` | Lead: running test Runners |
| Waiting | `◉ waiting` | Lead: blocked on dependency |
| Merging | `◉ merging` | Foreman: merging Lead branches |
| Verifying | `◉ verifying` | Foreman: running final verification |
| Complete | `◉ complete` | Lead: deliverable finished |
| Error | `◉ error` | Agent hit an error |
| Idle | `◉ idle` | Not doing anything |

The `◉` indicator uses color: green for active states (planning, researching, executing, implementing, testing, merging, verifying), yellow for waiting, white for idle/complete, red for error.

#### 5.4 Data Source

The TUI subscribes to orchestration events broadcast by the Foreman via Registry. The Foreman already receives `:lead_message` updates with status information (see [orchestration.md](orchestration.md) §6.2). The TUI listens for a `{:job_status, agent_statuses}` broadcast that the Foreman emits whenever an agent's state changes.

The `agent_statuses` payload is a list of `%{id: String.t(), type: :foreman | :lead | :runner, state: atom(), label: String.t()}`.

### 6. Thinking Display

#### 6.1 Rendering

Thinking content from `:thinking_delta` provider events is rendered inline in the conversation, directly before the assistant's text response. Thinking text is styled distinctly:

- **Dimmed** — reduced brightness (ANSI dim attribute, `\e[2m`)
- **Italic** — `\e[3m`
- **Prefixed** — each thinking block starts with `[thinking: ` and ends with `]`

Example:
```
  [thinking: analyzing the auth module structure
   and checking for dependency cycles...]

  Assistant: The auth module has three main components...
```

#### 6.2 Streaming Behavior

Thinking tokens stream in real-time, just like text tokens. The TUI handles `:thinking_delta` events the same way it handles `:text_delta` — append to the current thinking block in assigns.

The thinking block appears as soon as the first `:thinking_delta` arrives. When `:text_delta` events begin, the thinking block is complete — no closing event is needed.

#### 6.3 Thinking Between Tool Calls

A single assistant turn may include multiple thinking blocks — one before the initial response, and additional ones after tool results when the model reasons about what to do next. Each thinking block renders inline at its position in the conversation flow:

```
  [thinking: I need to read the auth module first...]

  [Tool: read] src/auth.ex ✓

  [thinking: the module uses bcrypt, now I should
   check the test coverage...]

  [Tool: bash] mix test ✓ (3.2s)

  Assistant: The auth module uses bcrypt for password hashing...
```

#### 6.4 Scrollback

Thinking blocks are part of the conversation history and remain visible when scrolling back. They are not ephemeral.

### 7. Rendering

- **Streaming text.** LLM output renders token-by-token as it arrives via `handle_info` for `:text_delta` events. Appends to current assistant message in assigns.
- **Markdown rendering.** Parse with Earmark, render to ANSI escape codes via custom renderer. Bold, italic, inline code, fenced code blocks (with language label), bullet/numbered lists. Streaming partial markdown: buffer the last incomplete line; only render complete blocks.
- **Tool execution display.** Each tool call: tool name + key argument, spinner while running, ✓/✗ + duration on completion.
- **Scrollback.** Conversation area is scrollable. User can scroll up while agent continues.

### 8. Status Bar

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

### 9. Input Handling

- **Enter** — submit prompt
- **Multi-line:** Shift+Enter (Kitty protocol), `\` + Enter (fallback), paste detection (chars within 5ms = literal newlines)
- **Up/Down** — recall input history when in input area
- **Page Up/Down** — scroll conversation
- **Ctrl+C** — abort current operation / exit if idle
- **Ctrl+D** — exit (standard Unix EOF)
- **Ctrl+L** — clear screen
- **Ctrl+R** — toggle raw output (no markdown rendering)
- **Esc** — cancel current input / abort

### 10. Slash Commands

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

### 11. Session Picker View

Lists sessions from `Deft.Session.Store.list/0`. Shows: session ID, working_dir, last timestamp, message count. Arrow keys to navigate, Enter to select and resume.

## Notes

### Design decisions

- **Thinking always visible (not collapsed).** Users need confidence the agent is working. Collapsed thinking hides the most useful signal for understanding what's happening. Dimmed styling keeps it visually subordinate to actual output.
- **Roster in conversation area, not a sidebar.** A true sidebar splits the terminal and complicates the Breeze layout. Right-aligned text overlay in the conversation area is simpler and sufficient — the roster is small (typically 3-5 lines).
- **Repo name in header, not status bar.** The repo rarely changes within a session, so it belongs in the chrome, not in the dynamic status bar. Frees status bar space for runtime metrics.
- **User always talks to Foreman.** No agent-switching UI needed. The Foreman is the single point of contact; Leads and Runners are visible but not directly addressable.

### Open questions

- **Alt screen vs scrollback.** Breeze likely uses alt screen (box model). Coding agent users prefer scrollback (native Cmd+F, text selection). Need to verify and decide.
- **Markdown-to-ANSI.** No Elixir library exists. Options: Earmark AST → custom renderer, or MDEx (Rust NIF via comrak). Streaming partial markdown needs buffering.
- **Terminal compatibility.** Test on: iTerm2, Terminal.app, WezTerm/Kitty, GNOME Terminal/Alacritty. Graceful degradation for terminals without 24-bit color or extended keyboard protocols.
- **Thinking token cost.** Thinking tokens can be verbose. Should there be a max display height (e.g., 10 lines) with "... N more lines" truncation? Or always show everything?

## References

- [Breeze](https://github.com/Gazler/breeze)
- [Earmark](https://github.com/pragdave/earmark)
- [Termite](https://github.com/Gazler/termite)
- [harness.md](harness.md) — agent events
- [providers.md](providers.md) — thinking_delta events
- [orchestration.md](orchestration.md) — agent status events
