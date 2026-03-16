# memory History

<!-- Completed work items, newest first. Do not group by spec — just append at the top. -->

- **providers v0.1 (2026-03-16):** Implement `Deft.Provider.Anthropic.model_config/1`: return context_window, max_output, input/output pricing for claude-sonnet-4, claude-opus-4, claude-haiku-4.5
- **providers v0.1 (2026-03-16):** Implement `Deft.Provider.Anthropic.format_tools/1`: convert tool modules to Anthropic `tools` array with `name`, `description`, `input_schema`
- **tools v0.1 (2026-03-16):** Define `Deft.Tool` behaviour with `name/0`, `description/0`, `parameters/0`, `execute/2` callbacks; define `Deft.Tool.Context` struct with `working_dir`, `session_id`, `emit`, `file_scope`
- **providers v0.1 (2026-03-16):** Implement `Deft.Provider.Anthropic.format_messages/1`: convert `Deft.Message` list to Anthropic wire format — system message to top-level `system` param, user/assistant with content arrays, tool_use/tool_result content blocks
- **providers v0.1 (2026-03-16):** Implement `Deft.Provider.Anthropic.parse_event/1`: map `content_block_start/delta/stop` and `message_delta/stop` to common event types per spec section 4 event mapping table
- **providers v0.1 (2026-03-16):** Implement SSE parser layer: pipe raw Req chunks through `ServerSentEvents.parse/1`, buffer partial lines, feed complete events to `parse_event/1`
- **providers v0.1 (2026-03-16):** Implement `Deft.Provider.Anthropic.stream/3`: POST to `https://api.anthropic.com/v1/messages` with `stream: true` via Req with `into: :self`, read `ANTHROPIC_API_KEY` from env (fail fast if missing), send `{:provider_event, event}` to caller, return stream ref; implement `cancel_stream/1` to close the connection
- **harness v0.1 (2026-03-16):** Implement `Deft.Agent.SystemPrompt.build/1`: role definition + tool descriptions from registered tools' name/0 + description/0 + parameters/0 + working dir + git branch + date + OS + conflict resolution rules
- **harness v0.1 (2026-03-16):** Implement `Deft.Agent.Context.build/2`: assemble message list — system prompt + observation injection point (empty initially) + conversation history + project context (DEFT.md/CLAUDE.md/AGENTS.md from working_dir)
- **harness v0.1 (2026-03-16):** Implement prompt queueing: queue prompts received in non-idle states, deliver on return to `:idle`
- **harness v0.1 (2026-03-16):** Implement turn limit: counter incremented on `:executing_tools → :calling`, reset on user prompt; at limit, pause-and-ask via event broadcast
- **harness v0.1 (2026-03-16):** Implement abort: on `{:abort}` in any state, cancel stream via `cancel_stream/1` if streaming, terminate in-flight tasks if executing_tools, transition to `:idle`
- **harness v0.1 (2026-03-16):** Implement `:executing_tools` state: fan out tool calls via `Task.Supervisor.async_nolink` under `Deft.Agent.ToolRunner`, collect results with `Task.yield_many/2` + timeouts, append tool_result messages, transition to `:calling` if tool results present or `:idle` if no tool calls
- **harness v0.1 (2026-03-16):** Implement `:streaming` state: accumulate `:text_delta` into assistant message content, accumulate `:tool_call_delta` into tool call args, on `:done` event transition to `:executing_tools`
- **harness v0.1 (2026-03-16):** Implement `:calling → :streaming` transition: on first `{:provider_event, _}` info message, transition to `:streaming`; on error, retry with exponential backoff up to 3 times, then `:idle` with error
- **harness v0.1 (2026-03-16):** Implement `:idle → :calling` transition: on `{:prompt, text}` cast, append user message to history, call provider.stream/3 with assembled context
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
