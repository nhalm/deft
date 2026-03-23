# TUI

| | |
|--------|----------------------------------------------|
| Version | 0.5 |
| Status | Deprecated |
| Last Updated | 2026-03-23 |

## Changelog

### v0.5 (2026-03-23)
- Replaced Breeze/Phoenix with Termite-direct architecture
- Three-layer design: Renderer (pure functions), View (GenServer), Terminal (Termite adapter)
- Added test adapter for terminal I/O — all rendering and event handling testable without a real TTY
- Removed BackBreeze box model — rendering is plain IO.ANSI string building
- Kept EarmarkParser for markdown-to-ANSI (unchanged)

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

The TUI (Terminal User Interface) is Deft's primary user interface. Built directly on Termite (terminal I/O adapter), it provides a chat interface with streaming LLM output, tool execution display, and an always-visible status bar.

**Scope:**
- TUI startup and lifecycle
- Three-layer architecture: Renderer, View, Terminal
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
- Test infrastructure for all TUI layers

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

### 1. Architecture

Three layers, each independently testable:

```
┌─────────────────────────────────────────────────┐
│  Renderer (pure functions)                      │
│  State → ANSI strings                           │
│  No side effects. Fully unit-testable.          │
├─────────────────────────────────────────────────┤
│  View (GenServer)                               │
│  Owns state. Handles events. Calls Renderer.    │
│  Testable by sending messages, checking state.  │
├─────────────────────────────────────────────────┤
│  Terminal (Termite adapter)                     │
│  Reads input, writes output. Swappable.         │
│  Real terminal in prod, test adapter in tests.  │
└─────────────────────────────────────────────────┘
```

#### 1.1 Renderer (`Deft.TUI.Renderer`)

Pure functions. No process state, no side effects. Takes a state map, returns ANSI strings.

```elixir
Renderer.render_frame(state) :: String.t()
Renderer.render_header(state) :: String.t()
Renderer.render_conversation(state) :: String.t()
Renderer.render_input(state) :: String.t()
Renderer.render_status_bar(state) :: String.t()
Renderer.render_thinking(text) :: String.t()
Renderer.render_tool(tool_info) :: String.t()
Renderer.render_agent_roster(agent_statuses, width) :: String.t()
```

`render_frame/1` composes the full screen: header + conversation + input + status bar. Uses IO.ANSI for styling — bold, dim, italic, colors. No Phoenix, no HEEx, no templates. Just string interpolation and `IO.ANSI`.

The frame is built for the current terminal dimensions (width × height passed in state). The conversation area fills available vertical space between header, input, and status bar.

#### 1.2 View (`Deft.TUI.View`)

A GenServer that owns the TUI state. Responsibilities:

- Holds all assigns (messages, streaming state, tools, tokens, etc.)
- Subscribes to agent events via Registry
- Handles `handle_info` for `:agent_event`, `:om_event`, `:job_status` messages
- Handles keyboard input from the terminal reader process
- On each state change, calls `Renderer.render_frame(state)` and writes the result to the terminal

The View does NOT interact with `prim_tty` directly. It calls a terminal writer function (injected at start) that writes the rendered string. In tests, this writer is a capture function.

```elixir
# Production
Deft.TUI.View.start_link(%{
  session_id: session_id,
  agent_pid: agent_pid,
  config: config,
  working_dir: working_dir,
  terminal: Deft.TUI.Terminal.new()  # real terminal
})

# Tests
Deft.TUI.View.start_link(%{
  session_id: session_id,
  agent_pid: agent_pid,
  config: config,
  working_dir: working_dir,
  terminal: Deft.TUI.Terminal.Test.new(test_pid)  # captures output
})
```

**State shape:** The View's state is a plain map with the same fields as the current chat.ex assigns — session_id, agent_pid, config, messages, current_text, current_thinking, streaming, agent_state, input, active_tools, token tracking, OM state, job/roster state, etc.

#### 1.3 Terminal (`Deft.TUI.Terminal`)

A behaviour wrapping Termite for terminal I/O:

```elixir
@callback start() :: {:ok, t()}
@callback write(t(), String.t()) :: :ok
@callback size(t()) :: {width :: integer(), height :: integer()}
@callback stop(t()) :: :ok
```

**Production implementation** (`Deft.TUI.Terminal.Live`): Uses `Termite.Terminal.start/0` for prim_tty access. Writes via `Termite.Terminal.write/2`. Reads input via the Termite reader process (messages to the View's mailbox). Handles alt screen enter/exit, cursor show/hide.

**Test implementation** (`Deft.TUI.Terminal.Test`): Captures all written output. Simulates input by sending messages. Returns configurable terminal size. No real TTY interaction.

### 2. Startup and Lifecycle

#### 2.1 Interactive Mode Startup

When the CLI starts an interactive session (`deft` or `deft resume`):

1. CLI creates the session and starts the Agent (existing flow)
2. CLI starts the terminal: `{:ok, terminal} = Deft.TUI.Terminal.Live.start()`
3. CLI starts the view: `Deft.TUI.View.start_link(%{..., terminal: terminal})`
4. CLI blocks until the View exits

#### 2.2 Resume Flow

- **With session ID** (`deft resume <id>`): Reconstruct session, start View with restored conversation
- **Without session ID** (`deft resume`): Start a simpler session picker (renders list, handles arrow keys + Enter). On selection, start the full View.

#### 2.3 Shutdown

- `/quit` or Ctrl+D — View exits cleanly, terminal restored
- Ctrl+C while idle — same as `/quit`
- Ctrl+C while agent working — first press aborts agent, second press exits

On shutdown or crash, the terminal must be restored. The CLI wraps View startup in `try/after` that calls `Terminal.stop/1` to exit alt screen, show cursor, reset attributes.

### 3. Rendering

All rendering is IO.ANSI string building. No templates, no box model.

#### 3.1 Frame Layout

```
\e[H                              ← cursor to top-left
<header line>                     ← 1 line, bold
<separator>                       ← 1 line of ─
<conversation area>               ← fills remaining height - 4
<separator>                       ← 1 line of ─
> <input text>                    ← 1 line
<separator>                       ← 1 line of ─
<status bar>                      ← 1 line
```

On each render, the View clears the screen and writes the full frame. Rendering is fast enough for 30 token/sec streaming — it's just string concatenation and a single write call.

#### 3.2 Header

Solo mode:
```
Deft ─ myapp ──────────────── model: claude-sonnet-4 ─ Solo
```

Orchestration mode:
```
Deft ─ myapp ──────────────────────── Foreman ◉ executing
```

Repo name is basename of working_dir git root, truncated to 20 chars.

#### 3.3 Conversation Area

Shows messages in order: user prompts, thinking blocks, assistant text, tool calls.

- **User messages:** plain text, prefixed with `User: `
- **Thinking blocks:** dim + italic (`\e[2;3m`), wrapped in `[thinking: ...]`
- **Assistant text:** normal weight
- **Tool calls:** `[Tool: name] arg ✓/✗ (duration)`
- **Streaming cursor:** `▊` appended during streaming

The conversation area height is `terminal_height - 5` (header, 2 separators, input, status). If content exceeds the area, show the most recent messages (auto-scroll). User can scroll up with Page Up/Down.

#### 3.4 Agent Roster (Orchestration)

Right-aligned in the top of the conversation area during orchestration:

```
                                     Foreman  ◉ executing
                                     Lead A   ◉ implementing
                                     Lead B   ◉ waiting
```

Colored `◉`: green (active), yellow (waiting), white (idle/complete), red (error). Uses ANSI color codes directly.

#### 3.5 Status Bar

```
12.4k/200k │ memory: -- │ $0.12 │ turn 2/25 │ ◉ idle
```

During orchestration:
```
2 leads │ 1/2 complete │ $1.24/$10 │ 4m elapsed │ ◉ executing
```

#### 3.6 Markdown Rendering

Kept from current implementation. `Deft.TUI.Markdown` uses EarmarkParser to parse markdown AST, then renders to ANSI: bold, italic, inline code (with background), fenced code blocks, lists. No dependency on Breeze or Phoenix.

### 4. Input Handling

The View receives keyboard input from the Termite reader as `{reader_ref, {:data, key}}` messages.

- **Enter** — submit prompt to agent
- **Multi-line:** Shift+Enter (Kitty protocol), `\` + Enter (fallback), paste detection
- **Up/Down** — input history recall
- **Page Up/Down** — scroll conversation
- **Ctrl+C** — abort / exit (double-press)
- **Ctrl+D** — exit
- **Ctrl+L** — force redraw
- **Ctrl+R** — toggle raw output
- **Esc** — cancel input

Slash commands recognized by leading `/`. Dispatched before reaching agent.

### 5. Thinking Display

Thinking tokens from `:thinking_delta` events render inline, dim + italic, prefixed with `[thinking: ...]`. Multiple thinking blocks per turn supported (between tool calls). Persist in scrollback.

### 6. Event Handling

The View subscribes to:
- `{:session, session_id}` — agent events (text_delta, thinking_delta, tool_call_start/done, state_change, usage, error)
- `{:job_status, session_id}` — orchestration roster updates

Each event updates the View's state and triggers a re-render. The event handling logic is the same as current chat.ex `handle_info` — this code moves largely intact from chat.ex to View.

### 7. Testing

#### 7.1 Renderer Tests

Pure function tests. No processes, no terminal.

```elixir
test "renders header with repo name and model in solo mode" do
  state = %{repo_name: "myapp", model_name: "claude-sonnet-4", job_active: false, ...}
  header = Renderer.render_header(state)
  assert header =~ "Deft ─ myapp"
  assert header =~ "Solo"
end

test "renders thinking block with dim italic styling" do
  result = Renderer.render_thinking("analyzing the code...")
  assert result =~ "\e[2;3m"
  assert result =~ "[thinking: analyzing the code...]"
end

test "renders agent roster right-aligned with colored indicators" do
  statuses = [%{label: "Foreman", state: :executing}, %{label: "Lead A", state: :waiting}]
  roster = Renderer.render_agent_roster(statuses, 80)
  assert roster =~ "\e[32m◉\e[0m executing"   # green
  assert roster =~ "\e[33m◉\e[0m waiting"      # yellow
end
```

#### 7.2 View Tests

GenServer tests using the test terminal adapter.

```elixir
test "updates state on text_delta event" do
  {:ok, view} = View.start_link(%{..., terminal: Terminal.Test.new(self())})
  send(view, {:agent_event, {:text_delta, "hello"}})
  state = :sys.get_state(view)
  assert state.current_text == "hello"
end

test "submits prompt to agent on Enter key" do
  {:ok, view} = View.start_link(%{..., terminal: Terminal.Test.new(self())})
  # Simulate typing + Enter
  send(view, {:terminal_input, "explain auth\n"})
  assert_receive {:prompt_sent, "explain auth"}
end

test "renders frame to terminal on state change" do
  {:ok, view} = View.start_link(%{..., terminal: Terminal.Test.new(self())})
  send(view, {:agent_event, {:state_change, :streaming}})
  assert_receive {:terminal_write, frame}
  assert frame =~ "◉ streaming"
end
```

#### 7.3 Integration Tests

End-to-end tests that start a View with a mock Agent, send events, and verify terminal output.

```elixir
test "full conversation flow renders correctly" do
  {:ok, agent} = MockAgent.start_link()
  {:ok, view} = View.start_link(%{agent_pid: agent, terminal: Terminal.Test.new(self()), ...})

  # User sends prompt
  send(view, {:terminal_input, "explain auth\n"})

  # Agent streams thinking
  send(view, {:agent_event, {:thinking_delta, "let me look at the code"}})
  assert_receive {:terminal_write, frame}
  assert frame =~ "[thinking:"

  # Agent streams response
  send(view, {:agent_event, {:text_delta, "The auth module"}})
  assert_receive {:terminal_write, frame}
  assert frame =~ "The auth module"
end
```

### 8. Dependencies

**Added (direct):**
- `termite` — terminal I/O (already a transitive dep, now direct)
- `earmark_parser` — markdown parsing (already a dep)

**Removed:**
- `breeze` (and its transitive deps: `back_breeze`, `phoenix_live_view`, `phoenix_html`, `phoenix_template`, `phoenix_pubsub`, `phoenix_component`)

### 9. Migration

Files to delete:
- `lib/deft/tui/breeze_poc.ex`

Files to rewrite:
- `lib/deft/tui/chat.ex` → split into `lib/deft/tui/renderer.ex` (pure rendering) and `lib/deft/tui/view.ex` (GenServer)
- `lib/deft/tui/session_picker.ex` → rewrite without Breeze
- `lib/deft/cli.ex` → replace Breeze.Server startup with View startup, remove `alias Breeze.Server`

Files to keep:
- `lib/deft/tui/markdown.ex` — no Breeze deps, works as-is

Files to create:
- `lib/deft/tui/terminal.ex` — behaviour
- `lib/deft/tui/terminal/live.ex` — production Termite implementation
- `lib/deft/tui/terminal/test.ex` — test adapter
- `lib/deft/tui/renderer.ex` — pure rendering functions
- `lib/deft/tui/view.ex` — GenServer
- `test/deft/tui/renderer_test.exs`
- `test/deft/tui/view_test.exs`

`mix.exs` changes:
- Remove `{:breeze, "~> 0.2"}`
- Add `{:termite, "~> 0.3"}` (direct dep instead of transitive)

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

## Notes

### Design decisions

- **Drop Breeze/Phoenix.** Breeze pulls in the entire Phoenix dependency tree for a single sigil (`~H`). It's buggy on OTP 28 (prim_tty name registration), its assign/render lifecycle doesn't work correctly, and it adds ~6 transitive deps. Terminal rendering is just string building — no framework needed.
- **Three-layer architecture.** Separating Renderer (pure), View (stateful), and Terminal (I/O) makes each layer independently testable. The Renderer can be tested with zero process overhead. The View can be tested with a fake terminal. Only smoke tests need a real TTY.
- **Termite direct.** Termite already has an adapter behaviour for swappable backends. We use it directly instead of through Breeze's wrapper.
- **IO.ANSI over templates.** Terminal output is simple string concatenation with escape codes. Templates add complexity (compilation, assigns tracking, struct lifecycle) with no benefit for this use case.
- **Test adapter over mocks.** A real `Terminal.Test` module that implements the behaviour is more reliable than Mox-style mocking. It captures writes and simulates input via message passing.

### Open questions

- **Alt screen vs scrollback.** Termite uses alt screen. Coding agent users may prefer scrollback (native Cmd+F, text selection). Investigate Termite's capabilities here.
- **Terminal compatibility.** Test on: iTerm2, Terminal.app, WezTerm/Kitty, Alacritty. Graceful degradation for terminals without 24-bit color.

## References

- [Termite](https://github.com/Gazler/termite) — terminal I/O adapter
- [Earmark](https://github.com/pragdave/earmark) — markdown parsing
- [IO.ANSI](https://hexdocs.pm/elixir/IO.ANSI.html) — ANSI escape codes
