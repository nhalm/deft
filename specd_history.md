# memory History

<!-- Completed work items, newest first. Do not group by spec — just append at the top. -->

- **standards v0.1 (2026-03-16):** Create `Makefile` with all targets from spec section 7: setup, deps, compile, format, format.check, lint, dialyzer, test, test.eval, test.integration, test.all, check, ci, clean
- **standards v0.1 (2026-03-16):** Create `lefthook.yml` with pre-commit (format, lint, compile) and pre-push (test, integration) hooks from spec section 8
- **standards v0.1 (2026-03-16):** Create `.credo.exs` with `strict: true` and the enabled checks from spec section 5
- **standards v0.1 (2026-03-16):** Create `.formatter.exs` with standard config (line_length: 98, standard inputs glob)
- **standards v0.1 (2026-03-16):** Scaffold Elixir Mix project: `mix.exs` with all deps from spec section 3, `Deft.Application` module, directory structure matching spec section 1 (lib/deft/agent/, om/, provider/, tools/, session/, tui/, job/)
