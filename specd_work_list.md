# Work List

<!--
Single execution queue for all work — spec implementations, audit findings, and promoted review items.

HOW IT WORKS:

1. Pick an unblocked item (no `(blocked: ...)` annotation)
2. Implement it
3. Validate cross-file dependencies
4. Move the completed item from this file to specd_history.md
5. Check this file for items whose `(blocked: ...)` annotation references the
   work you just completed — remove the annotation to unblock them
6. Delete the spec header in this file if no more items are under it
7. LOOP_COMPLETE when this file has no unblocked items remaining

POPULATED BY: /specd:plan command (during spec phase), /specd:audit command, /specd:review-intake command, and humans.
-->

## web-ui v0.4 + sessions v0.6

### prod.exs (CRITICAL — blocks release)
- Create `config/prod.exs` with `server: true` (without this the release binary won't start the HTTP listener), `adapter: Bandit.PhoenixAdapter`, `url: [host: "localhost"]`.

### Config files
- Update `config/config.exs` — ensure it has esbuild config for `assets/js/app.js` bundling and `import_config "#{config_env()}.exs"` at the bottom
- Update `config/dev.exs` — ensure `debug_errors: true`, `code_reloader: true`, `check_origin: false`, live_reload patterns for `.ex`, `.heex`, `.css`, `.js` (blocked: Update `config/config.exs`...)
- Update `config/runtime.exs` — add dynamic port from `PORT` env var (default 4000), generate `SECRET_KEY_BASE` via `:crypto.strong_rand_bytes(64) |> Base.encode64()` if not set in env (local tool, not a web service), read `ANTHROPIC_API_KEY` (blocked: Update `config/config.exs`...)

### Dynamic port selection
- Implement dynamic port selection: try port from config, if `:eaddrinuse` try 4001-4099. Write actual port to `~/.deft/projects/<path-encoded-repo>/server.pid`. Print `Deft running at http://localhost:<port>` on startup. This can be in `Deft.Application.start/2` after the endpoint starts, or in a custom `DeftWeb.Endpoint.init/2` callback. (blocked: Update `config/runtime.exs`...)

### Remove escript CLI code
- Remove `setup_sigint_handler/0` function and all `:os.set_signal(:sigint, :handle)` calls from `lib/deft/cli.ex`. Remove `restore_terminal/0`. Remove `alias Breeze.Server` and `@compile {:no_warn_undefined, Breeze.Terminal}`. In `start_web_ui/1`, the blocking is already `Process.sleep(:infinity)` — verify this is correct.

### Browser auto-open
- Add browser open to `start_web_ui/1` in cli.ex: after printing the URL, call `System.cmd("open", [url])` on macOS (detect via `:os.type()`) or `System.cmd("xdg-open", [url])` on Linux. Wrap in `try/rescue` so failure to open browser is a warning, not a crash. (blocked: Remove `setup_sigint_handler/0`...)

### Mix task for CLI dispatch
- Create `lib/mix/tasks/deft.ex` implementing `Mix.Tasks.Deft` — calls `Application.ensure_all_started(:deft)`, then delegates to `Deft.CLI.main(args)`. This allows `mix deft`, `mix deft work --loop`, `mix deft -p "prompt"`, `mix deft issue list` etc. All subcommands go through the same dispatcher. (blocked: Remove `setup_sigint_handler/0`...)

### Verify `mix deft` works end-to-end
- Run `mix deft` and confirm: (1) OTP app starts including Endpoint, (2) browser opens to `http://localhost:4000`, (3) web UI renders the chat interface, (4) Ctrl+C shuts down cleanly. Then test `mix deft -p "hello"` for non-interactive mode. (blocked: Create `lib/mix/tasks/deft.ex`...)

### Verify `mix deft work` and `mix deft issue` subcommands
- Run `mix deft issue list` and confirm it dispatches correctly through `Deft.CLI.main(["issue", "list"])`. Run `mix deft work` and confirm it dispatches to the work loop. These already work in cli.ex — just verify the Mix task wrapper passes args through correctly. (blocked: Verify `mix deft` works end-to-end...)

### Syntax highlighting
- Add highlight.js to `assets/js/app.js` — import from CDN or vendor bundle, call `hljs.highlightAll()` after each LiveView DOM update via a `phx-hook` on the conversation container. Style code blocks with a dark theme. (blocked: Update `config/dev.exs`...)

### Cleanup old TUI
- Delete `lib/deft/tui/` directory entirely (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex) — all functionality replaced by `lib/deft_web/`. Remove any remaining `Breeze` or `Termite` references from the codebase. (blocked: Verify `mix deft work` and `mix deft issue`...)

### Tests
- Verify all existing web UI tests still pass after changes — run `mix test test/deft_web/` and confirm 45+ tests, 0 failures. Run `mix test` for full suite. (blocked: Delete `lib/deft/tui/` directory...)
