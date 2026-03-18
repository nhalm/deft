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

## evals v0.2

- Implement Observer extraction evals: 9 test cases from spec section 2.1 (explicit tech choice, preference, file read, file modify, error, command, architecture, dependency, deferred work); 20 iterations, 85% pass rate (blocked: Implement Observer Task execution...)
- Implement Observer section routing evals: verify facts route to correct sections per spec section 2.2; 20 iterations, 85% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer anti-hallucination evals: 4 test cases from spec section 2.3 (hypothetical, exploring options, reading about, discussing alternatives); 20 iterations, 95% pass rate (blocked: Implement Observer extraction evals...)
- Implement Observer dedup evals: verify no re-extraction of existing observations; 20 iterations, 80% pass rate (blocked: Implement Observer extraction evals...)
- Implement Foreman decomposition evals: 1-3 deliverables, valid DAG, specific contracts; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Foreman constraint propagation evals: constraints from issue flow correctly to Lead steering instructions; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Foreman verification circuit breaker evals: verify Foreman correctly identifies broken work and does not mark it done; highest-priority eval — validates the safety net; 20 iterations, 90% pass rate (blocked: Implement Foreman gen_statem...)
- Implement Lead task planning evals: 4-8 tasks, dependency-ordered, clear done states; 20 iterations, 75% pass rate (blocked: Implement Lead gen_statem...)
- Implement Lead steering evals: identifies errors, provides specific corrections; 20 iterations, 75% pass rate (blocked: Implement Lead active steering...)
- Implement spilling cache retrieval evals: agent correctly uses cache_read tool when details not in summary; filter and lines parameters work; 20 iterations, 85% pass rate (blocked: Implement cache_read tool...)
- Implement issue→plan diagnostic eval: verify that structured issue fields (context, acceptance_criteria, constraints) flow correctly into Foreman research/planning/verification phases; 20 iterations, 75% pass rate (blocked: Implement Foreman gen_statem...)
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
- Fix `Deft.Project.resolve_git_root/1`: use `git rev-parse --git-common-dir` + `Path.dirname/1` instead of `--show-toplevel`; current code returns worktree root when running inside a Lead worktree, causing wrong project_dir path resolution; `Deft.Issues` already uses the correct pattern (blocked: Implement per-Lead worktree creation...)

## filesystem v0.2

- Fix Deft.Store `handle_call({:delete, ...})` to use sync flush for sitelog type: currently all deletes use `maybe_flush_buffer` (buffered); must check `state.type == :sitelog` and call `flush_buffer(new_state, sync: true)` like `do_write` does for writes (spec requires all site log writes to be synchronous with `:dets.sync/1`)
- Fix cache Store registry name mismatch: `Session.Worker` registers cache as `{:cache, session_id, "main"}` (worker.ex:51) but `ToolRunner.spill_to_cache` writes to `{:cache, session_id, "default"}` (tool_runner.ex:151); all cache spills silently fail via rescue; change tool_runner to use `"main"` or parameterize lead_id (spec section 6)
- Wire dynamic cache_read activation: `cache_active` config flag defaults to `false` and is never set to `true`; CacheRead tool is never added to agent tool list; must check Store for active entries after spilling and toggle `cache_active` + add CacheRead to tools (spec section 6.3, 6.4)
- Implement site log programmatic promotion: pattern match on Lead messages — auto-promote contract, decision, correction, critical_finding; promote finding if tagged shared; never promote status or blocker (blocked: Implement Deft.Store site log instance..., Implement Foreman gen_statem...)
- Implement per-Lead cache isolation: start one Deft.Store instance per Lead with DETS at cache/<session_id>/lead-<lead_id>.dets; Lead cleanup deletes its own cache instance (blocked: Implement Lead gen_statem...)
- Implement session-end cache cleanup: on session termination, delete all files under cache/<session_id>/ (blocked: Implement per-Lead cache isolation...)

## issues v0.2

- Fix `add_dependency/2` to return `:blocker_not_found` when blocker issue doesn't exist: currently both issue and blocker validation return `:not_found`; the `else` clause at line 359 collapses both failure modes (spec section 5.2 documents `:blocker_not_found` as a distinct error)
- Implement `deft issue dep add <id> --blocked-by <blocker_id>` and `dep remove` CLI commands (blocked: Implement dependency tracking...)
- Implement `deft work`: call ready/0, pick first, set status :in_progress, start Foreman job with issue structured JSON as prompt (context → research, acceptance_criteria → verification targets, constraints → Lead steering), on success set :closed + job_id, on failure set back to :open (blocked: Implement Foreman gen_statem...)
- Implement `deft work <id>`: same as `deft work` but for a specific issue ID, verify issue exists and is open (blocked: Implement deft work...)
- Implement `deft work --loop`: approve every plan by default (each issue gets plan approval checkpoint); --auto-approve-all flag skips all plan approvals for fully autonomous mode; stop when no ready issues remain, cumulative cost exceeds work.cost_ceiling, or user aborts; re-evaluate unblocked issues between jobs (blocked: Implement deft work...)
- Implement SIGINT handling: catch Ctrl+C, send graceful shutdown to Foreman, wait for current issue status rollback to :open (5-second timeout), then exit; if timeout expires, issue left at :in_progress (detected as stale on next startup) (blocked: Implement deft work --loop...)

## observational-memory v0.1

- Wire sync fallback calls from Agent.Context: `get_om_context/1` must check `pending_message_tokens` against 1.2x observation threshold (36,000) and call `OMState.force_observe/1`; check `observation_tokens` against 1.2x reflection threshold (48,000) and call `OMState.force_reflect/1`; currently no threshold check or sync fallback invocation exists (spec section 6.3)
- Add retry wrapper to async Observer Task: `spawn_observer_task` calls `Observer.run/4` directly with no retries; must wrap in retry logic (3 retries with exponential backoff) matching the existing `run_observer_with_retry` pattern used by the sync path (spec section 6.3)
- Pass calibration_factor from OM.State to Agent.Context: `get_om_context/1` hardcodes 4.0 (line 97 with TODO); must retrieve actual `calibration_factor` from State, which is updated via exponential moving average as LLM reports actual token counts (spec section 7)

## skills v0.2

- Fix `tools = []` in `continue_after_tools` and queued prompt path: `continue_after_tools/1` (line 1300) and `handle_idle_transition` queued prompt path (line 941) both hardcode `tools = []`; must use `Map.get(compacted_data.config, :tools, [])` like the initial `:calling` entry (line 208); agent loses all tools (including `use_skill`) after first tool execution round (spec section 2.5)
- Wire `Session.Supervisor.start_session/1` into CLI: `rescan_project/1` is only called from `start_session/1` but CLI calls `Agent.start_link/1` directly, bypassing it; project-level skills in `.deft/skills/` are never refreshed between sessions (spec section 5)

## tui v0.1

- Fix streaming markdown rendering: `handle_text_delta/2` appends raw text to `current_text` but render/1 displays it as a raw `<box>` with no markdown processing; must call `Markdown.render_streaming/1` during streaming to buffer incomplete lines and render complete blocks (spec section 3)
- Fix scroll_offset not applied to render: Page Up/Down handlers update `scroll_offset` assign but `render/1` iterates all messages with no offset or slicing applied; scrollback is non-functional (spec section 3)
