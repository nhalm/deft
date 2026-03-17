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

## observational-memory v0.1

- Implement Observer/Reflector serialization: if is_reflecting, defer Observer activation until reflection completes; if is_observing, defer reflection until Observer completes; activation_epoch incremented on both
- Implement sync fallback: on force_observe call, stash `from` in sync_from, spawn Task, return {:noreply}; on Task result, GenServer.reply(sync_from, result) and clear; on Task DOWN, reply with {:error, reason}; 1 retry max; 60s GenServer.call timeout (blocked: Implement Observer/Reflector serialization...)
- Implement circuit breaker: after 3 consecutive cycle failures, enter degraded mode (stop attempting), emit {:om, :circuit_open}, resume after 5-minute cooldown or /compact command (blocked: Implement sync fallback...)
- Implement hard observation cap: if observation_tokens > 60k, truncate oldest Session History entries, preserve all other sections and CORRECTION markers, emit {:om, :hard_cap_truncation}
- Implement `Deft.OM.Context.inject/2`: build observation system message with preamble + `<observations>` block + instructions + current task from Current State section; implement message trimming (filter out observed_message_ids, retain tail of 20% threshold); implement dynamic continuation hint from Current State section
- Add system prompt conflict resolution rule for observations: "If observations conflict with current messages, messages take precedence. If observations conflict with project instructions, project instructions take precedence"
- Implement OM event broadcasting via Registry: observation_started, observation_complete, reflection_started, reflection_complete, buffering_started, buffering_complete, activation, sync_fallback, cycle_failed, circuit_open, hard_cap_truncation
- Implement OM persistence: append observation snapshot to session JSONL after each activation + reflection activation + every 60s if snapshot_dirty; snapshot includes all persisted fields from spec section 9.2; use separate OM snapshot file to avoid JSONL write interleaving
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

## evals v0.2

- Create coding conversation fixtures: short bug-fix (5-10 exchanges), long feature session (50+ exchanges), multi-topic pivot, sessions with errors/corrections, heavy tool usage
- Implement Observer extraction evals: 9 test cases from spec section 2.1 (explicit tech choice, preference, file read, file modify, error, command, architecture, dependency, deferred work); 20 iterations, 85% pass rate (blocked: Implement Observer Task execution...)
- Implement Observer section routing evals: verify facts route to correct sections per spec section 2.2; 20 iterations, 85% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer anti-hallucination evals: 4 test cases from spec section 2.3 (hypothetical, exploring options, reading about, discussing alternatives); 20 iterations, 95% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer dedup evals: verify no re-extraction of existing observations; 20 iterations, 80% pass rate (blocked: Implement Observer extraction evals...)
- Implement Reflector compression evals: output within 50% of threshold; 20 iterations, 80% pass rate
- Implement Reflector preservation evals: all 🔴 items survive; 20 iterations, 95% pass rate (blocked: Implement Reflector compression evals...)
- Implement Reflector section structure evals: 5 sections in canonical order; hard assertion (not statistical), 100% pass rate (blocked: Implement Reflector compression evals...)
- Implement Reflector CORRECTION survival evals: all markers survive; hard assertion (not statistical), 100% pass rate (blocked: Implement Reflector compression evals...)
- Implement Actor observation usage evals: references observation content correctly; 20 iterations, 85% pass rate (blocked: Wire OM into Agent...)
- Implement Actor continuation evals: continues naturally after trimming, no greeting; 20 iterations, 90% pass rate (blocked: Wire OM into Agent...)
- Implement Foreman decomposition evals: 1-3 deliverables, valid DAG, specific contracts; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Foreman constraint propagation evals: constraints from issue flow correctly to Lead steering instructions; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Foreman verification circuit breaker evals: verify Foreman correctly identifies broken work and does not mark it done; highest-priority eval — validates the safety net; 20 iterations, 90% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Lead task planning evals: 4-8 tasks, dependency-ordered, clear done states; 20 iterations, 75% pass rate (blocked: Implement Lead gen_statem...)
- Implement Lead steering evals: identifies errors, provides specific corrections; 20 iterations, 75% pass rate (blocked: Implement Lead active steering...)
- Implement spilling summary quality evals: tool-specific summaries (grep match count + top N, read line count + first N lines, ls/find file count + top-level structure) preserve key information; 20 iterations, 85% pass rate (blocked: Implement tool result spilling protocol...)
- Implement spilling cache retrieval evals: agent correctly uses cache_read tool when details not in summary; filter and lines parameters work; 20 iterations, 85% pass rate (blocked: Implement cache_read tool...)
- Implement spilling threshold calibration grid search: test each tool's threshold across a range of values, measure summary quality vs context savings tradeoff; use to validate per-tool threshold defaults (blocked: Implement spilling summary quality evals...)
- Implement skill suggestion evals: agent suggests appropriate skill when context matches skill description; 20 iterations, 80% pass rate (blocked: Implement system prompt listing..., Implement use_skill tool...)
- Implement skill invocation fidelity evals: agent auto-invokes via use_skill tool correctly; skill definition is loaded and followed; 20 iterations, 80% pass rate (blocked: Implement skill suggestion evals...)
- Implement issue elicitation quality evals: interactive session produces structured issue with meaningful context, concrete acceptance_criteria, and actionable constraints; issue_draft tool call produces valid JSON; 20 iterations, 80% pass rate (blocked: Implement interactive issue creation session...)
- Implement issue→plan diagnostic eval: verify that structured issue fields (context, acceptance_criteria, constraints) flow correctly into Foreman research/planning/verification phases; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem..., Implement interactive issue creation session...)
- Implement agent-created issue quality evals: agent creates issues for discovered bugs/refactors with appropriate priority and context; does not create trivial issues; 20 iterations, 80% pass rate (blocked: Implement agent-created issues...)
- Build E2E task battery: create 3 synthetic repos (minimal Phoenix app, CLI tool, library with tests) with pre-defined issues; implement test harness that runs `deft work` against each repo and verifies acceptance criteria are met; track completion rate, cost, and duration (blocked: Implement deft work..., Create coding conversation fixtures...)
- Implement overnight loop safety eval: run `deft work --loop --auto-approve-all` against a synthetic repo with 5+ issues overnight; verify no runaway cost, no infinite loops, graceful SIGINT handling, correct issue status transitions; Tier 3 weekly schedule (blocked: Build E2E task battery...)

## orchestration v0.3

- Implement Foreman gen_statem: extends Agent with tuple states `{job_phase, agent_state}` using handle_event mode; phases: :planning, :researching, :decomposing, :executing, :verifying, :complete; single-agent fallback detection during :planning; Foreman handles `{:lead_message, type, content, metadata}` in handle_info for any state (blocked: Implement Deft.Job.Runner.run/1...)
- Implement research phase: Foreman spawns research Runners via Task.Supervisor.async_nolink in parallel (Sonnet model, read-only tools), collects findings from Task return values, configurable timeout (default 120s) via Process.send_after (blocked: Implement Foreman gen_statem...)
- Implement decomposition phase: Foreman reads research findings, produces deliverables + dependency DAG + interface contracts + cost estimate, writes plan to Deft.Store site log instance, presents to user for approval; --auto-approve-all flag skips approval gate (blocked: Implement research phase..., Implement Deft.Store site log instance...)
- Implement Lead gen_statem: extends Agent with tuple states `{chunk_phase, agent_state}`, receives deliverable assignment, decomposes into task list, spawns Runners via Task.Supervisor.async_nolink, Lead must explicitly Process.monitor(task.pid) for async_nolink Runners, actively steers (reads output, evaluates, corrects), handles `{:foreman_steering, content}` in handle_info; restart: :temporary in child spec (blocked: Implement Deft.Job.Runner.run/1...)
- Implement Runner inline loop: build minimal context → call LLM through RateLimiter → parse tool calls → execute tools inline with try/catch → loop until done → return results to Lead via Task return value; no gen_statem, no OM; Runner timeout via Process.send_after in Lead (blocked: Implement Deft.Job.RateLimiter dual token-bucket...)
- Implement Lead→Foreman messaging: Lead sends messages via `send(foreman_pid, {:lead_message, type, content, metadata})` for types: :status, :decision, :artifact, :contract, :contract_revision, :plan_amendment, :complete, :blocker, :error, :critical_finding (blocked: Implement Lead gen_statem...)
- Implement Foreman→Lead steering: Foreman sends `send(lead_pid, {:foreman_steering, content})` for course correction; detect conflicting :decision messages from parallel Leads, pause affected Leads, resolve or escalate to user (blocked: Implement Foreman gen_statem..., Implement Lead gen_statem...)
- Implement partial dependency unblocking: Foreman watches for {:lead_message, :contract, content, metadata} messages matching dependency `needs`, creates worktree for unblocked Lead, starts Lead with contract details (blocked: Implement decomposition phase..., Implement Lead gen_statem..., Implement per-Lead worktree creation...)
- Implement Deft.Store site log instance: Foreman creates a Deft.Store instance for curated job knowledge; programmatic promotion via pattern matching — auto-promote contract, decision, correction, critical_finding; promote finding if tagged shared; never promote status or blocker; site log uses sync DETS write + :dets.sync/1 (blocked: Implement Deft.Store GenServer..., Implement Foreman gen_statem...)
- Implement site log Lead read access: Leads obtain site log ETS tid via Deft.Store.tid/1 GenServer.call; Foreman passes site log registered name to each Lead at startup; ETS :protected allows Lead reads without GenServer calls (blocked: Implement Deft.Store site log instance..., Implement Lead gen_statem...)
- Implement contract versioning: :contract_revision Lead message type, Foreman re-steers downstream Leads on revision (blocked: Implement partial dependency unblocking...)
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report (blocked: Implement Foreman→Lead steering..., Implement merge in dependency order...)
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase..., Implement worktree cleanup...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement Deft.Store site log instance..., Implement verification phase...)

## rate-limiter v0.1

- Implement 429 handling: parse Retry-After header, reduce bucket capacity by 20% for affected provider, apply exponential backoff (1s, 2s, 4s, 8s... capped at 60s), restore capacity gradually after 60s without 429s (10% per minute up to configured limit) (blocked: Implement Deft.Job.RateLimiter dual token-bucket...)
- Implement adaptive concurrency: starting at job.initial_concurrency (default 2) Lead slots; scale-up signal (bucket >60% for 30s + zero queued calls → +1 slot up to job.max_leads); scale-down signal (>2 429s/min → -1 slot, minimum 1); send {:rate_limiter, :concurrency_change, new_limit} to Foreman (blocked: Implement 429 handling...)
- Implement cost tracking: read usage (input_tokens, output_tokens) from API responses, multiply by per-model pricing table; send {:rate_limiter, :cost, amount} to Foreman every $0.50 increment (not {:lead_message, ...}) (blocked: Implement Deft.Job.RateLimiter dual token-bucket...)
- Implement cost ceiling: pause job at cost_ceiling - $1.00 buffer; in-flight calls complete (slight overshoot accepted); no new calls dispatched until user approves continued spending (blocked: Implement cost tracking...)

## git-strategy v0.1

- Implement job branch creation: verify working tree is clean (warn + ask to stash if uncommitted changes), create `deft/job-<job_id>` branch from current HEAD (blocked: Implement Foreman gen_statem...)
- Implement per-Lead worktree creation: `git worktree add <repo>/.deft-worktrees/lead-<lead_id> -b deft/lead-<lead_id>` branched from job branch plus already-merged Lead work; Runners operate in Lead's worktree directory; Leads commit work per-task or per-milestone (blocked: Implement job branch creation...)
- Implement merge in dependency order: when Lead sends {:lead_message, :complete, ...}, Foreman merges Lead branch into deft/job-<job_id>; on conflict, spawn merge-resolution Runner; independent Leads merged in completion order (blocked: Implement per-Lead worktree creation..., Implement Lead gen_statem...)
- Implement post-merge test command: run configurable test command (not hardcoded `mix test`) on merged job branch after each Lead merge to catch semantic conflicts early; on failure, spawn fix-up Runner or flag for user intervention (blocked: Implement merge in dependency order...)
- Implement squash-merge on job complete: after verification passes, squash-merge deft/job-<job_id> into original branch (configurable: job.squash_on_complete, default true); delete job branch; verify no worktrees remain via `git worktree list` (blocked: Implement post-merge test command...)
- Implement worktree cleanup on Lead crash: Foreman cleans up Lead's worktree immediately on crash; use `git worktree remove --force` if index.lock exists (blocked: Implement per-Lead worktree creation...)
- Implement startup orphan cleanup: scan for orphaned deft/job-* branches and deft/lead-* worktrees with no running Deft job; interactive mode: user confirmation; non-interactive with --auto-approve: clean automatically; cleanup: worktree remove, branch -D, worktree prune- Add .deft-worktrees/ to .gitignore on first worktree creation if not already present (blocked: Implement per-Lead worktree creation...)

## filesystem v0.2

- Implement per-tool threshold config: cache.token_threshold (default 10000), cache.token_threshold.read (20000), cache.token_threshold.grep (8000), cache.token_threshold.ls (4000), cache.token_threshold.find (4000); provisional values pending threshold calibration evals
- Implement `cache_read` tool: parameters key (required), lines (optional line range), filter (optional grep pattern); returns full cached result or filtered subset; error cases :miss (not found) and :expired (session ended); only include in agent tool list when session has active cache entries
- Implement system prompt integration for cache spilling: when cache entries are active, include instruction about cache:// references and cache_read tool usage; remove instruction when no cache entries active (blocked: Implement cache_read tool...)
- Implement tool result spilling protocol: in Deft.Agent.ToolRunner, after tool execution check if result byte_size/4 exceeds tool's cache.token_threshold; if so, call tool's summarize/2 callback, write full result to cache, replace context entry with summary + cache://<key> reference
- Add summarize/2 callback to Deft.Tool behaviour: receives full result + cache key, returns summary string with cache://<key> reference; implement for grep (match count + top N), read (line count + first N lines), find/ls (file count + top-level structure) (blocked: Implement tool result spilling protocol...)
- Implement site log programmatic promotion: pattern match on Lead messages — auto-promote contract, decision, correction, critical_finding; promote finding if tagged shared; never promote status or blocker (blocked: Implement Deft.Store site log instance..., Implement Foreman gen_statem...)
- Implement per-Lead cache isolation: start one Deft.Store instance per Lead with DETS at cache/<session_id>/lead-<lead_id>.dets; Lead cleanup deletes its own cache instance (blocked: Implement Lead gen_statem...)
- Implement session-end cache cleanup: on session termination, delete all files under cache/<session_id>/ (blocked: Implement per-Lead cache isolation...)

## skills v0.2

- Implement `Deft.Skills.Registry` as Agent: on init, scan built-in (priv/skills/*.yaml, priv/commands/*.md), global (~/.deft/skills/*.yaml, ~/.deft/commands/*.md), project (.deft/skills/*.yaml, .deft/commands/*.md); parse YAML manifests using String.split(content, "\n---\n", parts: 2) on first part only; do NOT use YamlElixir.read_all_from_string; files missing --- separator are manifest-only (cannot be invoked); apply cascade (project > global > built-in); single namespace — skill wins at same cascade level; hold map of name → Entry struct- Define `Deft.Skills.Entry` struct: name, type (:skill | :command), level (:builtin | :global | :project), description, path, loaded (boolean)- Implement error handling in Registry discovery: skip skill YAML files that fail to parse with warning; skip skills with missing required fields (name, description) with warning; missing directories treated as empty (not an error) (blocked: Implement Deft.Skills.Registry...)
- Implement `Deft.Skills.Registry.list/0`: return all entries sorted by name; implement `lookup/1`: return entry by name or :not_found (blocked: Implement Deft.Skills.Registry...)
- Implement `Deft.Skills.Registry.load_definition/1`: use Agent.get_and_update/2 to atomically read and cache the definition (avoid read/cache race); for skills, read YAML file, parse content after --- separator, cache in registry (set loaded: true), return definition string; for commands, read markdown file contents (blocked: Implement Deft.Skills.Registry...)
- Implement `use_skill` tool for agent auto-invocation: agent emits use_skill tool call with skill name; harness intercepts, loads full definition from Registry, injects into context, continues agent loop; same mechanism as explicit slash command invocation (blocked: Implement Deft.Skills.Registry...)
- Add skills/commands listing to system prompt: assemble "Available skills:" and "Available commands:" sections from Registry.list/0 with names + descriptions; include in system prompt build (blocked: Implement Deft.Skills.Registry...)
- Implement slash command dispatch clarification: TUI intercepts leading / in user input, parses command name + args, looks up in Registry, loads definition if skill, injects as system instruction (skill) or user message (command); report "Unknown command" if not found (blocked: Implement Deft.Skills.Registry...)
- Implement naming validation: reject files not matching ^[a-z][a-z0-9-]*$, log warning during discovery (blocked: Implement Deft.Skills.Registry...)
- Implement project-level re-scan on session start: on each new session, re-run discovery for .deft/skills/ and .deft/commands/ to pick up changes; built-in and global skills persist across sessions (blocked: Implement Deft.Skills.Registry...)

## issues v0.2

- Define `Deft.Issue` struct with all schema fields: id, title, context, acceptance_criteria (list of strings), constraints (list of strings), status (:open/:in_progress/:closed), priority (0-4), dependencies (list of IDs), created_at, updated_at, closed_at, source (:user/:agent), job_id; include JSON encode/decode; all timestamps use DateTime.utc_now() |> DateTime.to_iso8601()- Implement `Deft.Issue.Id.generate/1`: derive 4-hex-char ID from random UUID with `deft-` prefix, accept existing IDs list, extend to 5+ chars on collision (blocked: Define Deft.Issue struct...)
- Implement `Deft.Issues` GenServer: init reads .deft/issues.jsonl into memory with dedup-on-read (last occurrence per ID wins); lines that fail JSON parsing are skipped with warnings (file not corrupt unless all lines malformed); holds list of Issue structs in state; expose create/1, update/2, close/1, get/1, list/1, ready/0 (blocked: Define Deft.Issue struct...)
- Implement cycle detection on load: after loading from JSONL in init/1, detect cycles in dependency graph; affected issues have dependencies cleared with warnings logged (blocked: Implement Deft.Issues GenServer...)
- Implement JSONL persistence with advisory lock: lock file at .deft/issues.jsonl.lock with exclusive create; lock file contains PID and timestamp as JSON line; stale threshold 30s; retry 100ms with jitter, 10s timeout; writes go to .deft/issues.jsonl.tmp.<random> then File.rename/2 (blocked: Implement Deft.Issues GenServer...)
- Implement worktree awareness: detect worktree via `git rev-parse --git-common-dir`, resolve .deft/issues.jsonl to main repo path; use Deft.Git behaviour for testability (blocked: Implement Deft.Issues GenServer...)
- Implement git behavior outside repos: when not inside a git repository, create .deft/ in cwd; skip worktree detection (blocked: Implement worktree awareness...)
- Implement dependency tracking: add_dependency/2 and remove_dependency/2 on Issues GenServer; circular dependency detection — walk graph on add, reject with error if cycle found (blocked: Implement Deft.Issues GenServer...)
- Implement ready/blocked queries: ready/0 returns open issues where all dependencies are closed, sorted by priority (0 first) then created_at (oldest first); blocked/0 returns open issues with at least one non-closed dependency (blocked: Implement dependency tracking...)
- Add .deft/issues.jsonl merge=union to .gitattributes on first `deft issue create` if not already present (blocked: Implement JSONL persistence...)
- Implement interactive issue creation session: `deft issue create <title>` starts lightweight Agent session (no OM) with elicitation system prompt; asks clarifying questions about context, acceptance criteria, constraints, dependencies; agent uses issue_draft tool call for structured output (JSON with title, context, acceptance_criteria, constraints, priority); CLI parses tool call result and presents for confirmation; saves to JSONL on confirm (blocked: Implement Deft.Issues GenServer...)
- Implement --quick flag for issue creation: skip interactive session, create issue with title only (empty context, acceptance_criteria, constraints) (blocked: Implement interactive issue creation session...)
- Implement issue_create tool for agent-created issues: accessible during any session; source set to :agent; default priority 3 (low) but agent may assign higher priority for discovered bugs affecting current functionality; agent explains priority choice in issue context (blocked: Implement Deft.Issues GenServer...)
- Implement `deft issue show <id>` CLI command: display all structured fields formatted for terminal (blocked: Implement Deft.Issues GenServer...)
- Implement `deft issue list` CLI command: default shows open + in_progress; --status filter, --priority filter; tabular output with id, priority, status, title (blocked: Implement Deft.Issues GenServer...)
- Implement `deft issue update <id>` CLI command: --title, --priority, --status, --blocked-by flags; call Issues.update/2 (blocked: Implement Deft.Issues GenServer...)
- Implement `deft issue close <id>` CLI command: set status to :closed, set closed_at, print any newly unblocked issues (blocked: Implement Deft.Issues GenServer...)
- Implement `deft issue ready` CLI command: call ready/0, display sorted list (blocked: Implement ready/blocked queries...)
- Implement `deft issue dep add <id> --blocked-by <blocker_id>` and `dep remove` CLI commands (blocked: Implement dependency tracking..., Implement Deft.Issues GenServer...)
- Implement `deft work`: call ready/0, pick first, set status :in_progress, start Foreman job with issue structured JSON as prompt (context → research, acceptance_criteria → verification targets, constraints → Lead steering), on success set :closed + job_id, on failure set back to :open (blocked: Implement ready/blocked queries..., Implement Foreman gen_statem...)
- Implement `deft work <id>`: same as `deft work` but for a specific issue ID, verify issue exists and is open (blocked: Implement deft work...)
- Implement `deft work --loop`: approve every plan by default (each issue gets plan approval checkpoint); --auto-approve-all flag skips all plan approvals for fully autonomous mode; stop when no ready issues remain, cumulative cost exceeds work.cost_ceiling, or user aborts; re-evaluate unblocked issues between jobs (blocked: Implement deft work...)
- Implement SIGINT handling: catch Ctrl+C, send graceful shutdown to Foreman, wait for current issue status rollback to :open (5-second timeout), then exit; if timeout expires, issue left at :in_progress (detected as stale on next startup) (blocked: Implement deft work --loop...)
- Implement closed issue compaction: on startup, remove issues with status :closed and closed_at older than issues.compaction_days (default 90); atomic JSONL rewrite; log "Compacted N closed issues older than 90 days" (blocked: Implement Deft.Issues GenServer...)
- Implement unblock notification: when an issue is closed, check if any blocked issues became ready, log to user output (blocked: Implement ready/blocked queries...)
