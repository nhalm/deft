# Web UI

| | |
|--------|----------------------------------------------|
| Version | 0.2 |
| Status | Ready |
| Last Updated | 2026-03-23 |

## Changelog

### v0.2 (2026-03-23)
- Added `:turn_limit_reached` to event handling list — UI must prompt user to continue or abort

### v0.1 (2026-03-23)
- Initial spec — Phoenix LiveView web interface replacing terminal TUI
- Vim/tmux keybindings, responsive layout, real-time streaming
- Supersedes tui.md

## Overview

The Web UI is Deft's primary user interface. Built on Phoenix LiveView, it provides a real-time chat interface with streaming LLM output, tool execution display, agent roster, and vim/tmux-style keyboard navigation. Runs as a local web server — `deft` starts Phoenix on localhost, opens the browser.

**Scope:**
- Phoenix application setup (endpoint, router, LiveView)
- Chat view (streaming conversation, tool display, thinking)
- Agent identity and roster display
- Status bar
- Vim/tmux keybindings (modal input, pane management)
- Responsive layout (desktop, tablet, mobile)
- Session picker
- Slash command dispatch
- Testing strategy (LiveViewTest)

**Out of scope:**
- Agent loop logic (see [harness.md](harness.md))
- Slash command implementations (each spec owns its commands; Web UI just dispatches)
- Non-interactive mode (`deft -p`) — uses stdio, no web server (see [sessions.md](sessions.md))
- Authentication — localhost only, single user (future: multi-user, auth)
- Remote access / tunneling (future)

**Dependencies:**
- [standards.md](standards.md) — coding standards
- [harness.md](harness.md) — agent events that the UI subscribes to
- [sessions.md](sessions.md) — CLI entry point, session creation, resume flow
- [observational-memory.md](observational-memory.md) — OM events for status display
- [providers.md](providers.md) — `:thinking_delta` events for thinking display
- [orchestration.md](orchestration.md) — Lead/Runner status for agent roster

## Specification

### 1. Architecture

```
Browser (LiveView client JS)
    ↕ WebSocket
Phoenix Endpoint (localhost:4000)
    ↕ PubSub
Deft.Agent (gen_statem)
```

The LiveView process subscribes to agent events via `Deft.Registry` (same mechanism the old TUI used). On each event, it updates assigns and Phoenix pushes the diff to the browser. No polling, no custom WebSocket code — this is standard LiveView.

#### 1.1 Phoenix Application

Phoenix runs inside the existing `Deft.Application` supervision tree:

```
Deft.Supervisor
├── Deft.Provider.Registry
├── Deft.Skills.Registry
├── Deft.Session.Supervisor
├── Phoenix.PubSub (name: Deft.PubSub)
└── DeftWeb.Endpoint (Phoenix.Endpoint)
```

The endpoint serves on `localhost:4000` (configurable). No Ecto, no database — Deft already has its own persistence (JSONL sessions, DETS store).

#### 1.2 Router

```elixir
live "/", DeftWeb.ChatLive        # main chat interface
live "/sessions", DeftWeb.SessionsLive  # session picker
```

### 2. Chat View (`DeftWeb.ChatLive`)

The primary interface. A single LiveView that handles conversation, streaming, tools, thinking, and the agent roster.

#### 2.1 Layout

```
┌──────────────────────────────────────────────────────────┐
│ Deft ─ myapp            Foreman ◉ executing    [status] │  ← header bar
├──────────────────────────────────────────────────────────┤
│                                          │ Foreman  ◉   │
│  [thinking: analyzing the auth module    │ Lead A   ◉   │  ← roster panel
│   structure and dependencies...]         │ Lead B   ◉   │     (collapsible)
│                                          │ Runner   ◉   │
│  User: explain the auth module           │               │
│                                          │               │
│  Assistant: The auth module handles...   │               │
│  ▊                                       │               │
│                                          │               │
│  [Tool: read] src/auth.ex ✓             │               │
│  [Tool: bash] mix test ✓ (3.2s)         │               │
│                                          │               │
├──────────────────────────────────────────────────────────┤
│ > input area                                      [INS] │  ← input + mode
├──────────────────────────────────────────────────────────┤
│ 12.4k/200k │ memory: -- │ $0.12 │ turn 2/25 │ ◉ idle   │  ← status bar
└──────────────────────────────────────────────────────────┘
```

Implemented with CSS Grid. The roster panel is a collapsible sidebar — hidden in solo mode, visible during orchestration. On narrow screens, the roster moves to a top bar or becomes a toggle overlay.

#### 2.2 Responsive Breakpoints

| Breakpoint | Layout |
|------------|--------|
| Desktop (>1024px) | Full layout with sidebar roster |
| Tablet (768-1024px) | Roster collapses to toggle overlay |
| Mobile (<768px) | Single column, roster as top bar summary, status bar wraps |

#### 2.3 Streaming

LiveView pushes text deltas to the browser as they arrive. The conversation area auto-scrolls to the bottom during streaming. User can scroll up to freeze auto-scroll; scrolling back to bottom re-enables it.

Streaming renders via a `phx-update="stream"` container for efficient DOM updates — LiveView only sends the new content, not the full conversation.

#### 2.4 Thinking Display

Thinking blocks render inline, styled distinctly:
- Light gray text on slightly darker background
- Italic
- Prefixed with `thinking:` label
- Collapsible (click to expand/collapse, default expanded)

Multiple thinking blocks per turn (between tool calls) each render at their position in the conversation flow.

#### 2.5 Tool Execution Display

Each tool call shows:
- Tool name and key argument
- Animated spinner while running (CSS animation, no JS needed)
- ✓/✗ icon and duration on completion
- Expandable: click to see full tool input/output

#### 2.6 Agent Roster

Sidebar panel showing all agents during orchestration:
- Each agent: name, colored status dot, state label
- Colors: green (active), yellow (waiting), gray (idle/complete), red (error)
- Click an agent to see its recent activity in a detail panel (future)

Hidden in solo mode. Uses CSS transitions for show/hide.

### 3. Header Bar

Shows:
- App name (`Deft`) + repo name (basename of working_dir)
- Agent identity: `Solo` or `Foreman`
- Agent state with colored indicator
- Quick-access buttons: settings, session picker, help

### 4. Input Area

Text input for user prompts. Supports:
- Multi-line input (Shift+Enter for newline, Enter to submit)
- Input history (Up/Down in normal mode)
- Slash command recognition (leading `/`)
- Vim mode indicator: `[NOR]`, `[INS]`, `[CMD]`

### 5. Status Bar

Always visible at bottom:

Solo mode:
```
12.4k/200k │ memory: 3.2k/40k │ $0.42 │ turn 3/25 │ ◉ idle
```

Orchestration mode:
```
2 leads │ 1/2 complete │ $1.24/$10 │ 4m elapsed │ ◉ executing
```

### 6. Keybindings

#### 6.1 Vim Modes

The chat interface supports three modes, tracked in LiveView assigns:

| Mode | Indicator | Behavior |
|------|-----------|----------|
| Normal | `[NOR]` | Navigation keys active, typing enters insert mode |
| Insert | `[INS]` | Text goes to input area, Esc returns to normal |
| Command | `[CMD]` | `:` prefix, slash commands, Esc cancels |

Default mode on page load: Insert (lowest friction for new users).

#### 6.2 Normal Mode Keys

| Key | Action |
|-----|--------|
| `i` | Enter insert mode |
| `a` | Enter insert mode (append) |
| `/` | Enter command mode |
| `:` | Enter command mode |
| `j` / `k` | Scroll conversation down/up |
| `G` | Scroll to bottom |
| `gg` | Scroll to top |
| `Ctrl+u` / `Ctrl+d` | Half-page scroll up/down |
| `Esc` | Clear selection, cancel |

#### 6.3 Tmux-style Pane Keys

Prefix: `Ctrl+b` (configurable), followed by:

| Key | Action |
|-----|--------|
| `%` | Toggle roster panel (vertical split) |
| `x` | Close active panel |
| `h` / `l` | Focus left/right pane |
| `z` | Toggle zoom (maximize current pane) |

(future: file tree panel, output panel, additional splits)

#### 6.4 Global Keys (all modes)

| Key | Action |
|-----|--------|
| `Ctrl+c` | Abort current agent operation (first press) |
| `Ctrl+c Ctrl+c` | Force abort |
| `Ctrl+l` | Clear / redraw |

Key events are handled server-side via `phx-keydown` on the body element with `phx-key` matching. LiveView receives `%{"key" => key}` params.

### 7. Session Picker (`DeftWeb.SessionsLive`)

Lists available sessions. Shows session ID, working directory, last activity, message count, first line of last prompt. Sorted most-recent-first.

Keyboard navigation: `j`/`k` to move, Enter to select, `q` to go back.

### 8. Slash Commands

Recognized by leading `/` in input or via `:` in command mode. Same command set as before:

| Command | Description | Spec owner |
|---------|-------------|-----------|
| `/help` | Show available commands and shortcuts | web-ui |
| `/model <name>` | Switch model | sessions |
| `/clear` | Clear display | web-ui |
| `/compact` | Force compaction | harness |
| `/observations` | Show OM observations | observational-memory |
| `/forget <text>` | Mark observation for removal | observational-memory |
| `/correct <old> -> <new>` | Mark observation for correction | observational-memory |
| `/cost` | Show cost breakdown | sessions |
| `/status` | Show job status | orchestration |
| `/inspect <lead>` | Show Lead's Site Log entries | orchestration |
| `/plan` | Re-display approved plan | orchestration |
| `/quit` | Stop server and exit | web-ui |

### 9. Startup and Lifecycle

#### 9.1 Startup

When the CLI starts an interactive session:

1. CLI creates the session and starts the Agent (existing flow)
2. CLI starts the Phoenix endpoint (`DeftWeb.Endpoint`)
3. CLI opens the browser: `System.cmd("open", ["http://localhost:4000"])` (macOS) or equivalent
4. CLI prints `Deft running at http://localhost:4000` and blocks

The LiveView mounts, subscribes to agent events, and is ready.

#### 9.2 Non-Interactive Mode

`deft -p "prompt"` — no web server, stdio only. Unchanged from current behavior.

#### 9.3 Shutdown

- `/quit` command or Ctrl+C in the terminal where `deft` is running
- Browser close does NOT shut down the server — user can reconnect
- LiveView reconnects automatically on network interruption (built-in)

### 10. Event Handling

The LiveView subscribes to agent events via `Deft.Registry`:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Registry.register(Deft.Registry, {:session, session_id}, [])
    Registry.register(Deft.Registry, {:job_status, session_id}, [])
  end
  # ...
end
```

Event handling in `handle_info`:
- `:text_delta` — append to streaming text, push via stream
- `:thinking_delta` — append to thinking block
- `:tool_call_start` / `:tool_call_done` — update tool status
- `:state_change` — update agent state indicator
- `:usage` — update token/cost counters
- `:error` — display error message
- `:turn_limit_reached` — show turn limit prompt, user can continue or abort
- `{:job_status, statuses}` — update agent roster

Each event updates assigns; LiveView diffs and pushes to browser automatically.

### 11. Testing

#### 11.1 LiveView Tests

```elixir
test "renders header with repo name in solo mode", %{conn: conn} do
  {:ok, view, html} = live(conn, "/")
  assert html =~ "Deft"
  assert html =~ "myapp"
  assert html =~ "Solo"
end

test "streams thinking delta to conversation" do
  {:ok, view, _html} = live(conn, "/")
  send(view.pid, {:agent_event, {:thinking_delta, "analyzing..."}})
  assert render(view) =~ "analyzing..."
  assert render(view) =~ "thinking"
end

test "submits prompt on Enter in insert mode" do
  {:ok, view, _html} = live(conn, "/")
  view |> element("#input") |> render_keydown(%{"key" => "Enter"})
  # assert agent received prompt
end

test "switches to normal mode on Esc" do
  {:ok, view, _html} = live(conn, "/")
  view |> element("body") |> render_keydown(%{"key" => "Escape"})
  assert render(view) =~ "[NOR]"
end

test "j/k scroll in normal mode" do
  {:ok, view, _html} = live(conn, "/")
  # Switch to normal mode
  view |> element("body") |> render_keydown(%{"key" => "Escape"})
  view |> element("body") |> render_keydown(%{"key" => "j"})
  # assert scroll position changed
end

test "shows agent roster during orchestration" do
  {:ok, view, _html} = live(conn, "/")
  send(view.pid, {:agent_event, {:job_status, [
    %{label: "Foreman", state: :executing},
    %{label: "Lead A", state: :implementing}
  ]}})
  html = render(view)
  assert html =~ "Foreman"
  assert html =~ "Lead A"
end
```

#### 11.2 Component Tests

Individual components (thinking block, tool display, status bar, roster) are testable as function components with `render_component/2`.

#### 11.3 Integration Tests

Full flow tests: mount LiveView, simulate user input, send agent events, verify rendered output. All synchronous, no real agent needed — just send events to the LiveView process.

### 12. Dependencies

**Added:**
- `phoenix` — web framework
- `phoenix_live_view` — real-time UI
- `phoenix_html` — HTML helpers
- `phoenix_live_reload` — dev hot reload (dev only)
- `jason` — JSON (likely already a dep)
- `bandit` — HTTP server (lightweight, Elixir-native)

**Removed:**
- `breeze` (and transitive: `back_breeze`, `termite`)
- All Phoenix deps that were transitive through Breeze are now direct (and actually used correctly)

**Kept:**
- `earmark_parser` — markdown rendering (render to HTML instead of ANSI now)

### 13. Migration

Files to delete:
- `lib/deft/tui/` — entire directory (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex)

Files to create:
- `lib/deft_web/endpoint.ex` — Phoenix endpoint
- `lib/deft_web/router.ex` — routes
- `lib/deft_web/live/chat_live.ex` — main chat LiveView
- `lib/deft_web/live/chat_live.html.heex` — chat template
- `lib/deft_web/live/sessions_live.ex` — session picker LiveView
- `lib/deft_web/components/` — thinking, tool, roster, status bar components
- `lib/deft_web/layouts/` — app layout
- `assets/css/app.css` — styles (Tailwind or plain CSS)
- `assets/js/app.js` — LiveView JS hooks (minimal — scroll control, focus management)
- `test/deft_web/live/chat_live_test.exs`
- `test/deft_web/live/sessions_live_test.exs`

Files to modify:
- `lib/deft/application.ex` — add Phoenix.PubSub and Endpoint to supervision tree
- `lib/deft/cli.ex` — replace Breeze startup with Endpoint startup + browser open
- `mix.exs` — swap deps
- `config/` — Phoenix endpoint config

Files to keep:
- Everything in `lib/deft/` except `lib/deft/tui/` — agent, tools, providers, sessions, OM, orchestration all unchanged

## Notes

### Design decisions

- **Phoenix LiveView over terminal UI.** Terminal rendering fights the terminal at every step — prim_tty compatibility, ANSI escape code math, alt screen vs scrollback, untestable without a real TTY. LiveView is purpose-built for real-time server-push UIs with mature testing support.
- **Vim/tmux keybindings over standard web shortcuts.** Target users are developers who live in vim/tmux. Modal input and prefix-based pane management match their muscle memory.
- **Default to Insert mode.** Lowest friction for new users and typing prompts. Vim users will instinctively hit Esc. Non-vim users never need to learn about modes.
- **Bandit over Cowboy.** Pure Elixir HTTP server, lighter weight, better defaults for a local dev tool.
- **No Tailwind initially.** Plain CSS keeps deps minimal. Can add Tailwind later if the styling gets complex.
- **Browser open on startup.** Minimal friction — `deft` just works. Print the URL as fallback for headless/SSH environments.
- **No auth.** Localhost only, single user. Auth is a future concern for remote access.

### Open questions

- **Port selection.** Fixed 4000, or find an open port? Multiple `deft` sessions on different projects would need different ports.
- **Dark/light theme.** Follow system preference via `prefers-color-scheme`? Configurable?
- **Markdown rendering.** Earmark can render to HTML directly (instead of ANSI). Use that, or a client-side renderer like marked.js?
- **Syntax highlighting for code blocks.** Server-side (Makeup) or client-side (highlight.js)?

## References

- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Phoenix LiveViewTest](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html)
- [Bandit](https://hexdocs.pm/bandit)
- [IO.ANSI](https://hexdocs.pm/elixir/IO.ANSI.html) — replaced by HTML/CSS
