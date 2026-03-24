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

## web-ui v0.3 + sessions v0.5

### Drop escript, fix mix.exs
- Remove `escript/0` function and `escript: escript()` from `project/0` in mix.exs. Add `{:esbuild, "~> 0.8", runtime: Mix.env() == :dev}` to deps. Run `mix deps.get`.
- Delete the `deft` escript binary from the repo root (it's a build artifact that should be in .gitignore)

### Phoenix config files
- Create `config/config.exs` with Phoenix endpoint config: `url: [host: "localhost"]`, `render_errors`, `pubsub_server: Deft.PubSub`, `live_view: [signing_salt: ...]`, esbuild config for `assets/js/app.js` bundling (blocked: Remove `escript/0` function...)
- Create `config/dev.exs` with `debug_errors: true`, `code_reloader: true`, `check_origin: false`, live_reload patterns for `.ex`, `.heex`, `.css`, `.js` files (blocked: Create `config/config.exs`...)
- Create `config/prod.exs` with `server: true`, `url: [host: "localhost"]` (blocked: Create `config/config.exs`...)
- Create `config/runtime.exs` with port from `PORT` env var (default 4000), secret_key_base generation via `:crypto.strong_rand_bytes/1` for dev (blocked: Create `config/config.exs`...)

### Dynamic port selection
- Add dynamic port selection to `DeftWeb.Endpoint` init or `Deft.Application`: try port from config, if `:eaddrinuse` increment through 4001-4099, store actual port in `~/.deft/projects/<path-encoded-repo>/server.pid`. Print actual URL with correct port on startup. (blocked: Create `config/runtime.exs`...)

### Remove escript CLI code
- Remove `setup_sigint_handler/0` and all `:os.set_signal` calls from `lib/deft/cli.ex` — replace `start_web_ui/1` signal-based blocking with `Process.sleep(:infinity)`. Remove `restore_terminal/0` and `alias Breeze.Server` and `@compile {:no_warn_undefined, Breeze.Terminal}`. (blocked: Remove `escript/0` function...)
- Remove the old interactive REPL functions if any remain in cli.ex: `interactive_loop/1`, `interactive_response_loop/0`, `process_prompt/2`, `send_to_agent/2` (blocked: Remove `setup_sigint_handler/0`...)

### Non-interactive Mix task
- Create `lib/mix/tasks/deft/prompt.ex` implementing `Mix.Tasks.Deft.Prompt` — parses args (`--model`, `--provider`, `--no-om`, `--working-dir`, `--output`), reads from stdin if no positional arg, starts agent (no Endpoint), sends prompt, streams response to stdout or file, exits. (blocked: Remove `escript/0` function...)
- Add `Deft.CLI.run_prompt/1` function for release eval mode — same logic as the Mix task but callable as `./bin/deft eval "Deft.CLI.run_prompt(\"prompt\")"` (blocked: Create `lib/mix/tasks/deft/prompt.ex`...)

### Conditional endpoint startup
- Update `lib/deft/application.ex` — start `DeftWeb.Endpoint` only when `Application.get_env(:deft, :start_endpoint, true)` is true. The Mix task sets this to false before starting the app. (blocked: Create `lib/mix/tasks/deft/prompt.ex`...)

### Syntax highlighting
- Add highlight.js to `assets/js/app.js` — import from CDN or bundle, call `hljs.highlightAll()` after each LiveView update via a hook on the conversation container. Style code blocks with the highlight.js dark theme. (blocked: Create `config/dev.exs`...)

### Cleanup old TUI
- Delete `lib/deft/tui/` directory entirely (chat.ex, session_picker.ex, breeze_poc.ex, markdown.ex) — all functionality replaced by `lib/deft_web/` (blocked: Conditional endpoint startup...)

### Tests
- Create `test/mix/tasks/deft/prompt_test.exs` — test that the Mix task parses args correctly, starts agent without Endpoint, streams response to stdout, handles `--output` flag (blocked: Create `lib/mix/tasks/deft/prompt.ex`...)
- Verify all existing web UI tests still pass after escript removal — run `mix test test/deft_web/` and confirm 45 tests, 0 failures (blocked: Delete `lib/deft/tui/` directory...)
