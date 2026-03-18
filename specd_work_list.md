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

- Implement Observer eval suite: extraction (9 test cases from spec section 2.1), priority, section routing, anti-hallucination (4 test cases from spec section 2.3), dedup; 20 iterations, 85%/95% pass rates per spec section 1.5
- Implement Reflector eval suite: compression (20 iters, 80%), preservation (20 iters, 95%), section structure (hard assertion), CORRECTION survival (hard assertion)
- Implement Actor eval suite: observation usage (20 iters, 85%), continuation (20 iters, 90%), tool selection (20 iters, 85%)
- Implement spilling eval suite: summary quality (20 iters, 85%), cache retrieval (20 iters, 85%), threshold calibration grid search
- Implement skills eval suite: suggestion (20 iters, 80%), invocation fidelity (20 iters, 80%)
- Implement issues eval suite: elicitation quality (20 iters, 80%), agent-created quality (20 iters, 80%)
- Implement Foreman eval suite: decomposition (20 iters, 75%), dependency, contract, constraint propagation, verification accuracy (blocked: Wire Foreman start_lead to actually start Lead gen_statem...)
- Implement Lead eval suite: task planning, steering (blocked: Wire Foreman start_lead to actually start Lead gen_statem...)
- Fix `mix eval.compare` load_run to distinguish corrupt JSONL data from missing run files: currently returns `{:error, :not_found, run_id}` for both cases (compare.ex:85-86); should return a distinct error when file exists but all lines fail JSON decode
- Implement issue→plan diagnostic eval: verify that structured issue fields (context, acceptance_criteria, constraints) flow correctly into Foreman research/planning/verification phases; 20 iterations, 75% pass rate (blocked: Implement deft work...)
- Build E2E task battery: create 3 synthetic repos (minimal Phoenix app, CLI tool, library with tests) with pre-defined issues; implement test harness that runs `deft work` against each repo and verifies acceptance criteria are met; track completion rate, cost, and duration (blocked: Implement deft work...)
- Implement overnight loop safety eval: run `deft work --loop --auto-approve-all` against a synthetic repo with 5+ issues overnight; verify no runaway cost, no infinite loops, graceful SIGINT handling, correct issue status transitions; Tier 3 weekly schedule (blocked: Build E2E task battery...)

## orchestration v0.3

- Add `{:rate_limiter, :cost_ceiling_reached, cost}` handler to Foreman: message from RateLimiter falls to catch-all and is silently dropped; Foreman must pause new Lead spawns when cost ceiling is reached (foreman.ex:569)
- Wire Foreman start_lead to actually start Lead gen_statem process and Process.monitor the PID: currently stores pid: nil and monitor_ref: nil (foreman.ex:1315-1323); blocks steering, crash detection, and merge
- Implement contract_matches? to verify published contract matches needed dependency: currently returns true for all contracts (foreman.ex:1339-1345), unblocking all waiting Leads regardless of actual dependency
- Implement extract_plan_from_messages to parse deliverables, dependencies, and contracts from LLM plan output: currently returns empty lists (foreman.ex:1200-1208), making execution phase non-functional (no Leads started)
- Fix Foreman/Lead to look up ToolRunner Task.Supervisor via session Registry via-tuple instead of bare module atom: foreman.ex:182 and lead.ex:188 use `Task.Supervisor.async_nolink(ToolRunner, ...)` but no process is registered under that atom in job context
- Fix Lead tool task handler to not consume runner completion messages: when in :executing_tools state, the tool handler at lead.ex:267 matches `{ref, results}` before the runner handler at lead.ex:297; if ref is a runner task, tool_tasks list is unchanged but message is consumed and runner result is lost
- Implement Foreman→Lead steering: Foreman sends `send(lead_pid, {:foreman_steering, content})` for course correction; detect conflicting :decision messages from parallel Leads, pause affected Leads, resolve or escalate to user (blocked: Wire Foreman start_lead to actually start Lead gen_statem..., Implement extract_plan_from_messages...)
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report (blocked: Implement Foreman→Lead steering..., Implement merge in dependency order...)
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase..., Implement worktree cleanup on Lead crash...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement verification phase...)

## rate-limiter v0.1

- Fix consecutive_429s reset: currently resets to 0 on every successful grant (rate_limiter.ex:372, 770), preventing exponential backoff from growing past 1s; should only reset after a sustained period without 429s, not on each individual success
- Implement cost_warning config and TUI notification: spec section 7 defines `job.cost_warning` at $5.00 default to display warning in TUI when reached; entirely absent from code — no config field, no threshold check, no message to Foreman
- Fix capacity restore timing: runs every 1s (queue check interval at rate_limiter.ex:196) after 60s grace period instead of once per minute; should_restore_capacity? (rate_limiter.ex:649-655) returns true on every tick after grace period because last_429_at is never updated during restore
- Fix capacity restore to use 10% of original capacity (linear) instead of 10% of current (compounding): rate_limiter.ex:176-177 uses `buckets.rpm.capacity * 1.1` which compounds; spec says "10% per minute" meaning fixed 10% of original limit

## git-strategy v0.1

- Fix Lead :complete message to include lead_id in metadata: Lead sends metadata `%{deliverable: ..., tasks_completed: ...}` without lead_id (lead.ex:697-705); Foreman does `Map.get(metadata, :lead_id)` which returns nil, so `Map.get(data.leads, nil)` returns nil and merge is skipped (foreman.ex:813-814)

## filesystem v0.2

- Fix resolve_git_root for normal (non-worktree) repos: `git rev-parse --git-common-dir` returns relative `.git`, `Path.dirname(".git")` returns `"."`, all normal repos map to same `~/.deft/projects/` directory (project.ex:131-138); must expand relative path against working dir before dirname
- Fix cache spill to use actual lead_id from context instead of hardcoded "main": tool_runner.ex:157 builds cache name as `{:cache, context.session_id, "main"}` regardless of which Lead is executing; breaks multi-Lead cache isolation
- Fix cache_read :expired error path: Store.read internally catches ArgumentError and returns :miss before cache_read.ex:75-79 rescue can trigger; :expired error message is unreachable; store.ex should propagate the ArgumentError for cleaned-up tables or cache_read should detect expired state differently
- Implement site log programmatic promotion: pattern match on Lead messages — auto-promote contract, decision, correction, critical_finding; promote finding if tagged shared; never promote status or blocker (blocked: Wire Foreman start_lead to actually start Lead gen_statem...)
- Implement per-Lead cache isolation: start one Deft.Store instance per Lead with DETS at cache/<session_id>/lead-<lead_id>.dets; Lead cleanup deletes its own cache instance (blocked: Wire Foreman start_lead to actually start Lead gen_statem...)
- Implement session-end cache cleanup: on session termination, delete all files under cache/<session_id>/ (blocked: Implement per-Lead cache isolation...)

## issues v0.2

- Implement `deft issue update --edit` flag: reopen conversational elicitation flow with existing fields pre-populated (spec section 5.2); not declared in OptionParser (cli.ex:96-117) and not handled in execute_command
- Fix compact_closed_issues timestamp comparison: cutoff uses `DateTime.to_iso8601()` without `DateTime.truncate(:second)` (issues.ex:483-485), producing fractional seconds like `.000000Z`; stored `closed_at` timestamps use truncated format; string comparison `<` gives wrong results when formats differ
- Implement `deft work`: call ready/0, pick first, set status :in_progress, start Foreman job with issue structured JSON as prompt (context → research, acceptance_criteria → verification targets, constraints → Lead steering), on success set :closed + job_id, on failure set back to :open
- Implement `deft work <id>`: same as `deft work` but for a specific issue ID, verify issue exists and is open (blocked: Implement deft work...)
- Implement `deft work --loop`: approve every plan by default (each issue gets plan approval checkpoint); --auto-approve-all flag skips all plan approvals for fully autonomous mode; stop when no ready issues remain, cumulative cost exceeds work.cost_ceiling, or user aborts; re-evaluate unblocked issues between jobs (blocked: Implement deft work...)
- Implement SIGINT handling: catch Ctrl+C, send graceful shutdown to Foreman, wait for current issue status rollback to :open (5-second timeout), then exit; if timeout expires, issue left at :in_progress (detected as stale on next startup) (blocked: Implement deft work --loop...)
