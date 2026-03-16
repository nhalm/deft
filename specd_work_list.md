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

BOOTSTRAP STRATEGY: Build enough to get a working `deft -p "prompt"` CLI agent.
Then use Deft to build the rest of Deft. The critical path is:
  standards → harness + providers + tools → sessions (non-interactive) → BOOTSTRAP DONE
  Then: OM → TUI → evals → orchestration
-->

---

## harness v0.1

- Implement `Deft.Agent` as gen_statem with `handle_event` callback mode, four states (`:idle`, `:calling`, `:streaming`, `:executing_tools`), state data holding conversation messages list, config, session_id
- Implement `:idle → :calling` transition: on `{:prompt, text}` cast, append user message to history, call provider.stream/3 with assembled context (blocked: Implement Deft.Agent gen_statem...)
- Implement `:calling → :streaming` transition: on first `{:provider_event, _}` info message, transition to `:streaming`; on error, retry with exponential backoff up to 3 times, then `:idle` with error (blocked: Implement Deft.Agent gen_statem...)
- Implement `:streaming` state: accumulate `:text_delta` into assistant message content, accumulate `:tool_call_delta` into tool call args, on `:done` event transition to `:executing_tools` (blocked: Implement Deft.Agent gen_statem...)
- Implement `:executing_tools` state: fan out tool calls via `Task.Supervisor.async_nolink` under `Deft.Agent.ToolRunner`, collect results with `Task.yield_many/2` + timeouts, append tool_result messages, transition to `:calling` if tool results present or `:idle` if no tool calls (blocked: Implement Deft.Agent gen_statem...)
- Implement abort: on `{:abort}` in any state, cancel stream via `cancel_stream/1` if streaming, terminate in-flight tasks if executing_tools, transition to `:idle` (blocked: Implement :executing_tools state...)
- Implement turn limit: counter incremented on `:executing_tools → :calling`, reset on user prompt; at limit, pause-and-ask via event broadcast (blocked: Implement :executing_tools state...)
- Implement prompt queueing: queue prompts received in non-idle states, deliver on return to `:idle` (blocked: Implement Deft.Agent gen_statem...)
- Implement `Deft.Agent.Context.build/2`: assemble message list — system prompt + observation injection point (empty initially) + conversation history + project context (DEFT.md/CLAUDE.md/AGENTS.md from working_dir) (blocked: Implement Deft.Agent gen_statem...)
- Implement `Deft.Agent.SystemPrompt.build/1`: role definition + tool descriptions from registered tools' name/0 + description/0 + parameters/0 + working dir + git branch + date + OS + conflict resolution rules
## providers v0.1

- Define `Deft.Provider` behaviour with `stream/3`, `cancel_stream/1`, `parse_event/1`, `format_messages/1`, `format_tools/1`, `model_config/1` callbacks; define common event type structs (`:text_delta`, `:thinking_delta`, `:tool_call_start`, `:tool_call_delta`, `:tool_call_done`, `:usage`, `:done`, `:error`)- Implement `Deft.Provider.Anthropic.stream/3`: POST to `https://api.anthropic.com/v1/messages` with `stream: true` via Req with `into: :self`, read `ANTHROPIC_API_KEY` from env (fail fast if missing), send `{:provider_event, event}` to caller, return stream ref; implement `cancel_stream/1` to close the connection (blocked: Define Deft.Provider behaviour...)
- Implement SSE parser layer: pipe raw Req chunks through `ServerSentEvents.decode/1`, buffer partial lines, feed complete events to `parse_event/1` (blocked: Implement Deft.Provider.Anthropic.stream/3...)
- Implement `Deft.Provider.Anthropic.parse_event/1`: map `content_block_start/delta/stop` and `message_delta/stop` to common event types per spec section 4 event mapping table (blocked: Implement SSE parser layer...)
- Implement `Deft.Provider.Anthropic.format_messages/1`: convert `Deft.Message` list to Anthropic wire format — system message to top-level `system` param, user/assistant with content arrays, tool_use/tool_result content blocks (blocked: Define Deft.Provider behaviour...)
- Implement `Deft.Provider.Anthropic.format_tools/1`: convert tool modules to Anthropic `tools` array with `name`, `description`, `input_schema` (blocked: Define Deft.Provider behaviour...)
- Implement `Deft.Provider.Anthropic.model_config/1`: return context_window, max_output, input/output pricing for claude-sonnet-4, claude-opus-4, claude-haiku-4.5 (blocked: Define Deft.Provider behaviour...)
- Create `Deft.Provider.Registry` GenServer: stores provider configs, resolves provider name + model name to module + config 
## tools v0.1

- Define `Deft.Tool` behaviour with `name/0`, `description/0`, `parameters/0`, `execute/2` callbacks; define `Deft.Tool.Context` struct with `working_dir`, `session_id`, `emit`, `file_scope`- Implement `Deft.Tools.Read`: read file with optional offset/limit, return content with line numbers, base64 for images (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Write`: write content to path, create parent dirs, return confirmation with byte count, check file_scope if set (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Edit`: string-match mode (unique old_string replacement, return unified diff, include nearby text on failure) + line-range mode (start_line/end_line/new_content), check file_scope if set (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Bash`: spawn via Port, stream stdout/stderr to context.emit, configurable timeout (default 120s), truncate to last 100 lines or 30KB, save full output to temp file (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Grep`: shell out to `rg`, support regex/glob/case_insensitive/context_lines, respect .gitignore, cap 100 matches; fall back to `:re` + `File.stream` if rg not installed (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Find`: shell out to `fd`, glob patterns, respect .gitignore, cap 1000 results; fall back to `Path.wildcard` if fd not installed (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Tools.Ls`: list directory via `File.ls/1`, return formatted listing with name, type, size (blocked: Define Deft.Tool behaviour...)
- Implement `Deft.Agent.ToolRunner`: start `Task.Supervisor`, expose `execute_batch/2` that spawns async_nolink tasks per tool call, collects results via `Task.yield_many/2` with per-task timeouts, catches exceptions (blocked: Define Deft.Tool behaviour...)

## sessions v0.1

- Implement `Deft.Session.Store`: `append/2` writes JSON line to `~/.deft/sessions/<session_id>.jsonl`, `load/1` reads and parses all lines, `list/0` returns session metadata sorted most-recent-first - Define entry type structs: session_start, message, tool_result, model_change, observation, compaction, cost- Implement session save: after each agent turn (transition to `:idle`), append message and tool_result entries to JSONL (blocked: Implement Deft.Session.Store...)
- Implement session resume: `load/1` reconstructs conversation state from entries, returns data for Agent gen_statem init (blocked: Implement Deft.Session.Store...)
- Implement `Deft.Config`: read and merge from CLI flags map → `.deft/config.yaml` in working_dir → `~/.deft/config.yaml` → defaults; parse YAML via yaml_elixir; return validated config struct - Implement `Deft.CLI`: parse args (deft, deft resume, deft resume <id>, deft config, -p, --model, --provider, --no-om, --working-dir, --output, --help, --version), load config, start OTP app (blocked: Implement Deft.Config...)
- Implement non-interactive mode: `deft -p "prompt"` creates session, sends prompt to Agent, streams text output to stdout, exits on `:idle`; piped input via stdin (blocked: Implement Deft.CLI...)
- Implement rg/fd startup check: verify in PATH via `System.find_executable/1`, warn to stderr if missing - Configure Burrito in mix.exs for single-binary builds: macOS (arm64, x86_64), Linux (x86_64, aarch64) (blocked: Implement Deft.CLI...)

## === BOOTSTRAP CHECKPOINT ===
<!-- After the above specs are implemented, `deft -p "prompt"` works as a CLI agent. -->
<!-- Use Deft (or Claude Code) to implement the remaining specs below. -->

## observational-memory v0.1

- Define `Deft.OM.State` struct with all fields from spec section 2: active_observations, observation_tokens, buffered_chunks, buffered_reflection, last_observed_at, observed_message_ids, pending_message_tokens, generation_count, is_observing, is_reflecting, needs_rebuffer, activation_epoch, snapshot_dirty, calibration_factor, sync_from - Define `Deft.OM.BufferedChunk` struct: observations, token_count, message_ids, message_tokens, epoch - Implement `Deft.OM.Tokens.estimate/1`: `div(byte_size(text), calibration_factor)` with configurable factor; implement `calibrate/2` via exponential moving average (alpha=0.1) - Implement `Deft.OM.Supervisor` (rest_for_one): starts TaskSupervisor first, then State (blocked: Define Deft.OM.State struct...)
- Implement `Deft.OM.State` GenServer: holds state struct, exposes `get_context/1` returning `{observations_text, observed_message_ids}`, `messages_added/2` that updates pending tokens and spawns Observer Tasks when thresholds approached; manages coalescing via `is_observing` + `needs_rebuffer` (blocked: Implement Deft.OM.Supervisor...)
- Implement Observer prompt: `Deft.OM.Observer.Prompt.system/0` with coding-specific extraction rules (user facts 🔴, files read/modified 🟡, errors 🟡, commands 🟡, architecture 🟡, deps 🟡, git state 🟡, TODOs 🟡), anti-hallucination rules, sectioned output format (Current State/User Preferences/Files & Architecture/Decisions/Session History) - Implement `Deft.OM.Observer.Prompt.format_messages/1`: format messages as `**Role (HH:MM):** content`, tool calls as `[Tool Call: name]`, tool results as `[Tool Result: name]`- Implement `Deft.OM.Observer.Prompt.truncate_observations/2`: given observations + 8k budget, take last 5k tokens (tail) + scan remainder for 🔴 lines filling to 3k + `[N observations truncated]` marker (blocked: Implement Deft.OM.Tokens.estimate...)
- Implement `Deft.OM.Observer.Parse.parse_output/1`: extract `<observations>` and `<current-task>` from XML; fallback to raw bullet-list extraction; validate section headers - Implement section-aware merge in State: Current State = replace, User Preferences/Decisions/Session History = append, Files & Architecture = append with dedup (same file path updates existing entry), unknown sections = ignore (blocked: Implement Deft.OM.State GenServer...)
- Implement Observer Task execution: State spawns Task under TaskSupervisor with current messages + truncated observations, handles result in `handle_info({ref, result})`, stores as BufferedChunk with current activation_epoch (blocked: Implement section-aware merge...)
- Implement observation activation: when pending_message_tokens >= threshold and buffered_chunks non-empty, section-aware merge all chunks into active_observations, move chunk message_ids to observed_message_ids, clear buffered_chunks, increment activation_epoch, set snapshot_dirty (blocked: Implement Observer Task execution...)
- Implement Reflector prompt: `Deft.OM.Reflector.Prompt.system/1` with target size (50% of threshold), compression levels 0-3, section ordering constraint, per-section budget guidance, CORRECTION marker preservation requirement - Implement Reflector Task execution: State spawns Task with full active_observations + target size; result replaces active_observations, increments generation_count + activation_epoch; max 2 LLM calls; CORRECTION post-check (append missing markers); if level 3 still exceeds target, accept and move on (blocked: Implement Deft.OM.State GenServer...)
- Implement Observer/Reflector serialization: if is_reflecting, defer Observer activation until reflection completes; if is_observing, defer reflection until Observer completes; activation_epoch incremented on both (blocked: Implement Reflector Task execution...)
- Implement sync fallback: on force_observe call, stash `from` in sync_from, spawn Task, return {:noreply}; on Task result, GenServer.reply(sync_from, result) and clear; on Task DOWN, reply with {:error, reason}; 1 retry max; 60s GenServer.call timeout (blocked: Implement Observer/Reflector serialization...)
- Implement circuit breaker: after 3 consecutive cycle failures, enter degraded mode (stop attempting), emit {:om, :circuit_open}, resume after 5-minute cooldown or /compact command (blocked: Implement sync fallback...)
- Implement hard observation cap: if observation_tokens > 60k, truncate oldest Session History entries, preserve all other sections and CORRECTION markers, emit {:om, :hard_cap_truncation} (blocked: Implement observation activation...)
- Implement `Deft.OM.Context.inject/2`: build observation system message with preamble + `<observations>` block + instructions + current task from Current State section; implement message trimming (filter out observed_message_ids, retain tail of 20% threshold); implement dynamic continuation hint from Current State section (blocked: Implement Deft.OM.State GenServer...)
- Implement OM event broadcasting via Registry: observation_started, observation_complete, reflection_started, reflection_complete, buffering_started, buffering_complete, activation, sync_fallback, cycle_failed, circuit_open, hard_cap_truncation (blocked: Implement Deft.OM.State GenServer...)
- Implement OM persistence: append observation snapshot to session JSONL after each activation + reflection activation + every 60s if snapshot_dirty; snapshot includes all persisted fields from spec section 9.2; use separate OM snapshot file to avoid JSONL write interleaving (blocked: Implement observation activation...)
- Implement OM resume: load latest snapshot, initialize State, recompute pending_message_tokens from messages not in observed_message_ids, trigger observation/reflection if thresholds exceeded (blocked: Implement OM persistence...)
- Wire OM into Agent: in Context.build/2, call State.get_context/1 for observations + observed IDs, inject observations, trim observed messages; after each turn, call State.messages_added/2 (blocked: Implement Deft.OM.Context.inject...)

## tui v0.1

- Build Breeze streaming proof-of-concept: 1000+ lines mixed text, 30 tokens/sec append, scrollable area + fixed input + status bar; verify performance is acceptable; if not, document fallback to Termite + BackBreeze - Implement `Deft.TUI.Chat` Breeze view: mount/2 subscribes to agent events via Registry, render/1 displays scrollable conversation + input + status bar (blocked: Build Breeze streaming proof-of-concept...)
- Implement streaming text display: handle_info for :text_delta events, append to current assistant message in assigns (blocked: Implement Deft.TUI.Chat...)
- Implement markdown-to-ANSI renderer: parse with Earmark, walk AST to emit ANSI codes for bold/italic/code/lists/fenced code blocks; streaming partial markdown: buffer last incomplete line - Implement tool execution display: tool name + key arg, spinner while running, ✓/✗ + duration on complete (blocked: Implement Deft.TUI.Chat...)
- Implement status bar: tokens (current/context_window), memory (obs_tokens/40k or "--" before first observation), cost, turn count, agent state; OM activity spinner during observation/reflection; "memorizing..." during sync fallback (blocked: Implement Deft.TUI.Chat...)
- Implement user input component: Enter submits, Shift+Enter newline (Kitty protocol), \ + Enter fallback, paste detection (chars within 5ms), Up arrow input history (blocked: Implement Deft.TUI.Chat...)
- Implement slash command dispatch: recognize leading `/`, parse command + args, dispatch to appropriate handler; implement /help, /clear, /quit directly; other commands dispatched to their spec owners (blocked: Implement user input component...)
- Implement `Deft.TUI.SessionPicker` Breeze view: list sessions, arrow keys to navigate, Enter to resume (blocked: Implement Deft.TUI.Chat...)
- Implement job status display in Chat view: per-Lead progress, blocked status, cost, elapsed time; /status and /inspect commands (blocked: Implement Deft.TUI.Chat...)

## evals v0.1

- Create eval test infrastructure: test/eval/ directory structure per spec, fixture loading helpers, pass rate tracking in baselines.json, regression detection - Create coding conversation fixtures: short bug-fix (5-10 exchanges), long feature session (50+ exchanges), multi-topic pivot, sessions with errors/corrections, heavy tool usage- Implement Observer extraction evals: 9 test cases from spec section 2.1 (explicit tech choice, preference, file read, file modify, error, command, architecture, dependency, deferred work); 85% pass rate (blocked: Implement Observer Task execution...)
- Implement Observer section routing evals: verify facts route to correct sections per spec section 2.2; 85% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer anti-hallucination evals: 4 test cases from spec section 2.3 (hypothetical, exploring options, reading about, discussing alternatives); 95% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer dedup evals: verify no re-extraction of existing observations; 80% pass rate (blocked: Implement Observer extraction evals...)
- Implement Reflector compression evals: output within 50% of threshold; 90% pass rate (blocked: Implement Reflector Task execution...)
- Implement Reflector preservation evals: all 🔴 items survive; 95% pass rate (blocked: Implement Reflector compression evals...)
- Implement Reflector section structure evals: 5 sections in canonical order; 95% pass rate (blocked: Implement Reflector compression evals...)
- Implement Reflector CORRECTION survival evals: all markers survive; 100% pass rate (blocked: Implement Reflector compression evals...)
- Implement Actor observation usage evals: references observation content correctly; 85% pass rate (blocked: Wire OM into Agent...)
- Implement Actor continuation evals: continues naturally after trimming, no greeting; 90% pass rate (blocked: Wire OM into Agent...)
- Implement Actor tool selection evals: picks correct tool per spec section 4.3; 85% pass rate (blocked: Implement all 7 tools...)
- Implement Foreman decomposition evals: 1-3 deliverables, valid DAG, specific contracts; 75% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Lead task planning evals: 4-8 tasks, dependency-ordered, clear done states; 75% pass rate (blocked: Implement Lead gen_statem...)
- Implement Lead steering evals: identifies errors, provides specific corrections; 75% pass rate (blocked: Implement Lead active steering...)

## orchestration v0.1

- Implement `Deft.Job.SiteLog` GenServer: owns JSONL file + ETS table (`:bag`, keyed by `{type, agent_id}`), writes via handle_call + handle_continue for async file I/O, reads via ETS directly; rebuild ETS from JSONL in init/1 on restart - Implement `Deft.Job.RateLimiter` GenServer: dual token-bucket (RPM + TPM) per provider, priority queue (Foreman > Runner > Lead), starvation protection (promote after 10s), auto-429 detection + capacity reduction, adaptive concurrency (scale-up when bucket >60% for 30s, scale-down on >2 429s/min), cost tracking from API usage responses, pause at ceiling - $1 buffer - Implement `Deft.Job.Runner.run/1`: inline agent loop function — build minimal context, call LLM via RateLimiter, parse tool calls, execute tools inline with try/catch, loop until done, write results to SiteLog, return to caller (blocked: Implement Deft.Job.SiteLog..., Implement Deft.Job.RateLimiter...)
- Implement Foreman gen_statem: extends Agent with tuple states `{job_phase, agent_state}` using handle_event mode; phases: :planning, :researching, :decomposing, :executing, :verifying, :complete; single-agent fallback detection during :planning (blocked: Implement Deft.Agent gen_statem..., Implement Deft.Job.Runner.run/1...)
- Implement research phase: Foreman spawns read-only Runners in parallel (Sonnet model), collects findings from SiteLog, 120s timeout (blocked: Implement Foreman gen_statem...)
- Implement decomposition phase: Foreman reads findings, produces deliverables + dependency DAG + interface contracts + cost estimate, writes plan to SiteLog, presents to user for approval; --auto-approve support (blocked: Implement research phase...)
- Implement Lead gen_statem: extends Agent with tuple states `{chunk_phase, agent_state}`, receives deliverable assignment, decomposes into task list, spawns Runners sequentially/parallel, actively steers (reads output, evaluates, corrects), runs mix compile after each Runner, posts status/decision/artifact/contract/complete entries to SiteLog; restart: :temporary in child spec (blocked: Implement Deft.Agent gen_statem..., Implement Deft.Job.Runner.run/1...)
- Implement partial dependency unblocking: Foreman watches SiteLog for `contract` entries matching dependency `needs`, creates worktree for unblocked Lead, posts steering with contract details (blocked: Implement decomposition phase..., Implement Lead gen_statem...)
- Implement git worktree management: Foreman creates job branch `deft/job-<id>`, creates per-Lead worktrees, handles merge in dependency order after Lead reports complete, spawns merge-resolution Runner on conflict, runs tests after each merge, cleans up worktrees after merge; startup orphan cleanup (blocked: Implement Lead gen_statem...)
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner that runs full test suite + reviews modified files for consistency; on pass, squash-merge job branch; on fail, identify responsible Lead and report (blocked: Implement git worktree management...)
- Implement job cleanup: Foreman cleans all worktrees, deletes job branch (or keeps on failure if configured), archives job files to ~/.deft/jobs/<id>/ (blocked: Implement verification phase...)
- Implement cost ceiling: RateLimiter tracks cumulative cost, emits cost entries to SiteLog every $0.50, Foreman pauses at ceiling - $1 buffer, asks user to approve additional spend (blocked: Implement Deft.Job.RateLimiter...)
- Implement contract versioning: `contract_revision` SiteLog entry type, Foreman re-steers downstream Leads on revision (blocked: Implement partial dependency unblocking...)

## issues v0.1

- Define `Deft.Issue` struct with all schema fields: id, title, context, acceptance_criteria (list of strings), constraints (list of strings), status (:open/:in_progress/:closed), priority (0-4), dependencies (list of IDs), created_at, updated_at, closed_at, source (:user/:agent), job_id; include JSON encode/decode - Implement `Deft.Issue.Id.generate/1`: derive 4-hex-char ID from random UUID with `deft-` prefix, accept existing IDs list, extend to 5+ chars on collision (blocked: Define Deft.Issue struct...)
- Implement `Deft.Issues` GenServer: init reads `.deft/issues.jsonl` into memory (dedup-on-read: last occurrence per ID wins), holds list of Issue structs in state; expose `create/1`, `update/2`, `close/1`, `get/1`, `list/1`, `ready/0` (blocked: Define Deft.Issue struct...)
- Implement JSONL persistence in `Deft.Issues`: atomic file rewrite (write to `.deft/issues.jsonl.tmp.<random>`, then `File.rename/2`); advisory file lock via `.deft/issues.jsonl.lock` with exclusive create, 30s stale threshold, 100ms retry with jitter, 10s timeout (blocked: Implement Deft.Issues GenServer...)
- Implement worktree awareness in `Deft.Issues`: detect worktree via `git rev-parse --git-common-dir`, resolve `.deft/issues.jsonl` to main repo path (blocked: Implement Deft.Issues GenServer...)
- Implement dependency tracking: `add_dependency/2` and `remove_dependency/2` on Issues GenServer; circular dependency detection — walk graph on add, reject with error if cycle found (blocked: Implement Deft.Issues GenServer...)
- Implement `ready/0` query: return open issues where all dependencies are closed, sorted by priority (0 first) then created_at (oldest first); implement `blocked/0` query: open issues with at least one non-closed dependency (blocked: Implement dependency tracking...)
- Add `.deft/issues.jsonl merge=union` to `.gitattributes` on first `deft issue create` if not already present (blocked: Implement JSONL persistence...)
- Implement interactive issue creation session: `deft issue create <title>` starts a lightweight Agent session (no OM) with elicitation system prompt; asks about context, acceptance criteria, constraints, dependencies; extracts structured fields from conversation; presents formatted issue for confirmation; saves to JSONL on confirm (blocked: Implement Deft.CLI..., Implement Deft.Issues GenServer..., Implement Deft.Agent gen_statem...)
- Implement `--quick` flag for `deft issue create`: skip interactive session, create issue with title only (empty context, acceptance_criteria, constraints) (blocked: Implement interactive issue creation session...)
- Implement `deft issue show <id>` CLI command: display all structured fields formatted for terminal (blocked: Implement interactive issue creation session...)
- Implement `deft issue list` CLI command: default shows open + in_progress, --status filter, --priority filter; tabular output with id, priority, status, title (blocked: Implement interactive issue creation session...)
- Implement `deft issue ready` CLI command: call ready/0, display sorted list (blocked: Implement ready/0 query...)
- Implement `deft issue update <id>` CLI command: --title, --priority, --status, --blocked-by flags; call Issues.update/2 (blocked: Implement interactive issue creation session...)
- Implement `deft issue close <id>` CLI command: set status to :closed, set closed_at, print any newly unblocked issues (blocked: Implement interactive issue creation session...)
- Implement `deft issue dep add <id> --blocked-by <blocker_id>` and `dep remove` CLI commands (blocked: Implement dependency tracking..., Implement interactive issue creation session...)
- Implement `deft work`: call ready/0, pick first, set status :in_progress, start Foreman job with issue structured JSON as prompt (context → research, acceptance_criteria → verification targets, constraints → Lead steering), on success set :closed + job_id, on failure set back to :open (blocked: Implement ready/0 query..., Implement Foreman gen_statem...)
- Implement `deft work <id>`: same as `deft work` but for a specific issue ID, verify issue exists and is open (blocked: Implement deft work...)
- Implement `deft work --loop`: single-approval mode — user approves first job's plan, subsequent jobs auto-approve; after closing an issue, check for more ready issues; stop when queue empty or cumulative cost exceeds work.cost_ceiling; re-evaluate unblocked issues between jobs (blocked: Implement deft work...)
- Implement closed issue compaction: on startup, remove issues with status :closed and closed_at older than `issues.compaction_days` (default 90); atomic JSONL rewrite; log "Compacted N closed issues older than 90 days" (blocked: Implement Deft.Issues GenServer...)
- Implement agent-created issues: add `issue_create` capability accessible during any session, source set to :agent, default priority 3; agent uses it for out-of-scope bugs, refactors, TODOs discovered during work (blocked: Implement Deft.Issues GenServer..., Implement Deft.Agent gen_statem...)
- Implement unblock notification: when an issue is closed, check if any blocked issues became ready, log to user output (blocked: Implement ready/0 query...)
