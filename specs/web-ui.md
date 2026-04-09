# Web UI

| | |
|--------|----------------------------------------------|
| Version | 0.8 |
| Status | Implemented |
| Last Updated | 2026-04-09 |

## Changelog

### v0.8 (2026-04-09)
- Remove auto-open browser on startup; print the URL to stdout only

### v0.7 (2026-04-08)
- Network access: endpoint binds to all interfaces (`0.0.0.0`), configurable origin checking via `CHECK_ORIGIN` env var with MFA callback on both sockets
- Tool details lazy-loaded via `GET /api/tool_detail/:session/:tool_call_id` instead of inline
- Streaming text rendered via `StreamingMarkdown` JS hook with server-side Earmark, bypassing LiveView DOM patching
- Inline activity indicator (Thinking/Working/Waiting/etc.) at bottom of conversation
- Header simplified to colored state dot only, removed agent identity and state text labels
- Session resume loads full conversation history from JSONL on mount

### v0.6 (2026-04-08)
- Startup auto-creates a new session and loads it immediately
- Header buttons use text labels, minimum 13px, adequate padding
- Sessions button opens `/sessions` in a new browser tab
- Session picker: visible selection highlight, mouse click support, both Enter and click open in new tab

### v0.5 (2026-03-25)
- Incremental content flushing: thinking, text, and tool blocks flush to the conversation stream as they complete, not batched on idle
- Fixes: thinking disappears mid-turn, tool results vanish, subsequent thinking steps never appear

### v0.4 (2026-03-24)
- Fixed startup architecture: unified CLI dispatcher replaces escript, see sessions.md §5
- Added Bandit adapter config (was defaulting to missing Cowboy)
- Added prod.exs with `server: true`
- Added esbuild for asset compilation
- Removed escript-specific code (setup_sigint_handler, restore_terminal)
- Resolved open questions: dynamic port selection, `prefers-color-scheme`, Earmark for markdown, highlight.js for syntax

### v0.3 (2026-03-24)
- Replaced escript with Mix release + Burrito for distribution
- Dev startup via `mix phx.server`, not escript
- Non-interactive mode (`deft -p`) runs as a Mix task instead of escript main
- Removed `setup_sigint_handler` — `:os.set_signal(:sigint, ...)` is invalid in escript mode and unnecessary with Mix/Phoenix
- Resolved open questions: dynamic port selection, `prefers-color-scheme`, server-side markdown via Earmark, client-side syntax highlighting via highlight.js

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
- Authentication (future: multi-user, auth)

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
Phoenix Endpoint (0.0.0.0:4000)
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

The endpoint binds to all interfaces on port 4000 (configurable via `PORT` env var). Origin checking is controlled by `CHECK_ORIGIN` env var — unset allows all origins, set to a comma-separated list of allowed origins (e.g. `//localhost,//192.168.10.13`). No Ecto, no database — Deft already has its own persistence (JSONL sessions, DETS store).

#### 1.2 Router

```elixir
live "/", DeftWeb.ChatLive        # main chat interface
live "/sessions", DeftWeb.SessionsLive  # session picker
get "/api/tool_detail/:session/:tool_call_id", DeftWeb.ToolDetailController, :show
```

### 2. Chat View (`DeftWeb.ChatLive`)

The primary interface. A single LiveView that handles conversation, streaming, tools, thinking, and the agent roster.

#### 2.0 Startup — Auto-create Session

When ChatLive mounts without a `?session=` param (i.e., user navigated to `/`), it creates a new session and loads it. Flow:

1. Generate a session ID
2. Create the session via `Deft.Session.Supervisor.start_session/1`
3. Update the URL to `/?session=<id>` (via `push_patch`) so refresh works
4. Subscribe to agent events and initialize the chat

When mounting with a `?session=<id>` param, ChatLive loads the full conversation history from the session JSONL and renders it into the stream. Resumed sessions show all past messages, thinking blocks, and tool calls.

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

Completed content blocks render via a `phx-update="stream"` container. The currently-streaming text block uses a `StreamingMarkdown` JS hook — the server renders markdown via Earmark and pushes pre-rendered HTML to the hook via `push_event`. This avoids LiveView DOM patching destroying the conversation stream during rapid updates.

**Content blocks persist incrementally.** Each content block (thinking, text, tool) becomes a permanent part of the conversation as soon as it completes — not batched at the end of the turn. During a multi-step turn the user sees a growing sequence of completed blocks above, with only the currently-streaming block at the bottom. Nothing disappears.

**Activity indicator.** While the agent is active, an inline indicator appears at the bottom of the conversation with a state-specific label: Thinking, Working, Waiting, Researching, Implementing, or Verifying. Hidden when idle.

#### 2.4 Thinking Display

Thinking blocks render inline, styled distinctly:
- Light gray text on slightly darker background
- Italic
- Prefixed with `thinking:` label
- Collapsible (click to expand/collapse, default expanded while streaming, auto-collapses once complete)

Multiple thinking blocks per turn (between tool calls) each render at their position in the conversation flow. Completed thinking blocks collapse so they don't dominate the view — the user can click to re-expand.

#### 2.5 Tool Execution Display

Each tool call renders as a compact card showing tool name, key argument, status icon (✓/✗), and duration. Tool input/output is lazy-loaded on click via `GET /api/tool_detail/:session/:tool_call_id` — the server reads details from the session JSONL. Client-side JS toggles the detail panel open/closed.

Completed tools persist in the conversation immediately — they don't wait for the turn to end.

#### 2.6 Agent Roster

Sidebar panel showing all agents during orchestration:
- Each agent: name, colored status dot, state label
- Colors: green (active), yellow (waiting), gray (idle/complete), red (error)
- Click an agent to see its recent activity in a detail panel (future)

Hidden in solo mode. Uses CSS transitions for show/hide.

### 3. Header Bar

Shows:
- App name (`Deft`) + repo name (basename of working_dir)
- Colored state dot (`◉`) — color reflects agent state
- Quick-access buttons with text labels:

| Button | Label | Action |
|--------|-------|--------|
| Sessions | `Sessions` | Opens `/sessions` in a new browser tab (`target="_blank"`) |
| Help | `Help` | Shows help overlay |

Buttons use the `.header-button` CSS class with readable font size (minimum 13px), visible border, and adequate padding (at least `6px 12px`). Each button has a text label.

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
| Normal | `Normal` | Navigation keys active, typing enters insert mode |
| Insert | `Insert` | Text goes to input area, Esc returns to normal |
| Command | `Command` | `:` prefix, slash commands, Esc cancels |

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

#### 7.1 Selection

The currently selected session must have a **visible highlight** — distinct background color (e.g., `var(--bg-tertiary)`) so the user can see which item is focused.

#### 7.2 Navigation

- **Keyboard:** `j`/`k` to move selection, Enter to open, `q` to go back
- **Mouse:** clicking a session item selects and opens it

#### 7.3 Opening Sessions

Both Enter and mouse click open the selected session in a new browser tab. Use `window.open("/?session=<id>", "_blank")` via a JS hook or `<a>` tag with `target="_blank"`. The session picker page stays open so the user can open multiple past sessions.

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

See [sessions.md](sessions.md) §5 for the full application runtime architecture, CLI dispatcher, and distribution model.

The web UI is the default mode — `deft` with no args starts the server and prints the URL to stdout. It does NOT auto-open a browser window. The endpoint always starts (even during `deft work`) so the web UI is available for monitoring running jobs.

#### 9.1 Shutdown

- Ctrl+C in the terminal where `deft` is running (standard BEAM shutdown)
- `/quit` command in the web UI calls `System.stop(0)`
- Browser close does NOT shut down the server — user can reconnect
- LiveView reconnects automatically on network interruption (built-in)

No custom signal handling needed — the BEAM's default Ctrl+C behavior is correct.

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
- `:text_delta` — append to streaming text
- `:thinking_delta` — append to thinking block
- `:tool_call_start` / `:tool_call_done` — update tool status
- `:tool_execution_complete` — tool finishes, persists to conversation
- `:state_change` — update agent state indicator
- `:usage` — update token/cost counters
- `:error` — display error message
- `:turn_limit_reached` — show turn limit prompt, user can continue or abort
- `{:job_status, statuses}` — update agent roster

Content blocks (thinking, text, tool) persist to the conversation stream incrementally as described in §2.3 — each block becomes permanent as soon as it completes, not batched on idle.

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

**Runtime:**
- `phoenix` — web framework
- `phoenix_live_view` — real-time UI
- `phoenix_html` — HTML helpers
- `bandit` — HTTP server (lightweight, Elixir-native). Must be configured as the adapter: `adapter: Bandit.PhoenixAdapter` in endpoint config.
- `jason` — JSON (already a dep)
- `earmark_parser` — markdown → HTML rendering (already a dep)
- `burrito` — single-binary distribution (already a dep)

**Dev/Test:**
- `phoenix_live_reload` — dev hot reload
- `floki` — HTML parsing for LiveView tests (already a dep)
- `esbuild` — JS bundling for app.js

**Removed:**
- `breeze` (and transitive: `back_breeze`, `termite`)
- Escript config from mix.exs (`escript/0` function, `escript: escript()` in `project/0`)

**Config files required:**
- `config/config.exs` — base Phoenix config, `adapter: Bandit.PhoenixAdapter`, LiveView signing salt
- `config/dev.exs` — `debug_errors: true`, `code_reloader: true`, live-reload patterns
- `config/prod.exs` — `server: true` (critical — without this the release won't start HTTP), Bandit adapter
- `config/runtime.exs` — `PORT` env var, `SECRET_KEY_BASE` (generate if not set), `ANTHROPIC_API_KEY`, `CHECK_ORIGIN`
- `config/test.exs` — `server: false`, port 4002

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
- `assets/css/app.css` — styles
- `assets/js/app.js` — LiveView JS hooks (scroll control, focus management)
- `lib/mix/tasks/deft/prompt.ex` — Mix task for non-interactive mode
- `test/deft_web/live/chat_live_test.exs`
- `test/deft_web/live/sessions_live_test.exs`

Files to modify:
- `lib/deft/application.ex` — add Phoenix.PubSub and Endpoint to supervision tree. Endpoint starts conditionally (not in non-interactive mode).
- `lib/deft/cli.ex` — remove escript-specific code (interactive_loop, Breeze aliases, setup_sigint_handler, restore_terminal). Simplify to just parse args and delegate to Application or Mix tasks.
- `mix.exs` — remove `escript/0` function and escript config from `project/0`. Add `esbuild` dep. Keep `releases/0` with Burrito.
- `config/config.exs` — Phoenix endpoint config, LiveView signing salt
- `config/dev.exs` — live-reload config, debug logging
- `config/prod.exs` — production endpoint config (server: true)
- `config/runtime.exs` — port from `PORT` env var, secret key base

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
- **No auth.** Single user. Auth is a future concern for multi-user access.
- **Mix release over escript.** Escript doesn't support `priv/` directory (needed for static assets), signal handling is broken, and hot-reload doesn't work. Mix release is the standard Phoenix distribution path. Burrito wraps the release into a single binary for the "just run `./deft`" experience.
- **Non-interactive as Mix task.** `mix deft.prompt` replaces `deft -p`. In the release, `./deft eval` provides the same capability. Keeps the CLI entry point simple.

### Resolved questions

- **Port selection.** Dynamic — try 4000, increment if in use. Store port in pidfile.
- **Dark/light theme.** Dark by default, respect `prefers-color-scheme`.
- **Markdown rendering.** Server-side via Earmark (already a dep, renders to HTML).
- **Syntax highlighting for code blocks.** Client-side via highlight.js (loaded from CDN or bundled). No server dep needed.

## References

- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Phoenix LiveViewTest](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html)
- [Bandit](https://hexdocs.pm/bandit)
- [IO.ANSI](https://hexdocs.pm/elixir/IO.ANSI.html) — replaced by HTML/CSS
