# memory History

<!-- Completed work items, newest first. Do not group by spec — just append at the top. -->

- **providers v0.1 (2026-03-16):** Define `Deft.Provider` behaviour with `stream/3`, `cancel_stream/1`, `parse_event/1`, `format_messages/1`, `format_tools/1`, `model_config/1` callbacks; define common event type structs (`:text_delta`, `:thinking_delta`, `:tool_call_start`, `:tool_call_delta`, `:tool_call_done`, `:usage`, `:done`, `:error`)
- **harness v0.1 (2026-03-16):** Implement `Deft.Agent` as gen_statem with `handle_event` callback mode, four states (`:idle`, `:calling`, `:streaming`, `:executing_tools`), state data holding conversation messages list, config, session_id
- **harness v0.1 (2026-03-16):** Create `Deft.Application` supervisor tree: `Deft.Supervisor` (one_for_one) with `Deft.Provider.Registry` (GenServer) and `Deft.Session.Supervisor` (DynamicSupervisor)
- **harness v0.1 (2026-03-16):** Define `Deft.Message` struct with `id`, `role`, `content`, `timestamp` fields and all ContentBlock types (Text, ToolUse, ToolResult, Thinking, Image) as structs with typespec
- **standards v0.1 (2026-03-16):** Run `make setup` to verify deps install, lefthook installs, `make check` passes on empty project
- **standards v0.1 (2026-03-16):** Create `Makefile` with all targets from spec section 7: setup, deps, compile, format, format.check, lint, dialyzer, test, test.eval, test.integration, test.all, check, ci, clean
- **standards v0.1 (2026-03-16):** Create `lefthook.yml` with pre-commit (format, lint, compile) and pre-push (test, integration) hooks from spec section 8
- **standards v0.1 (2026-03-16):** Create `.credo.exs` with `strict: true` and the enabled checks from spec section 5
- **standards v0.1 (2026-03-16):** Create `.formatter.exs` with standard config (line_length: 98, standard inputs glob)
- **standards v0.1 (2026-03-16):** Scaffold Elixir Mix project: `mix.exs` with all deps from spec section 3, `Deft.Application` module, directory structure matching spec section 1 (lib/deft/agent/, om/, provider/, tools/, session/, tui/, job/)
