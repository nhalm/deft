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

- Implement Foreman verification circuit breaker evals: verify Foreman correctly identifies broken work and does not mark it done; highest-priority eval — validates the safety net; 20 iterations, 90% pass rate
- Implement Lead task planning evals: 4-8 tasks, dependency-ordered, clear done states; 20 iterations, 75% pass rate
- Implement Lead steering evals: identifies errors, provides specific corrections; 20 iterations, 75% pass rate (blocked: Implement Lead active steering...)
- Implement issue→plan diagnostic eval: verify that structured issue fields (context, acceptance_criteria, constraints) flow correctly into Foreman research/planning/verification phases; 20 iterations, 75% pass rate - Build E2E task battery: create 3 synthetic repos (minimal Phoenix app, CLI tool, library with tests) with pre-defined issues; implement test harness that runs `deft work` against each repo and verifies acceptance criteria are met; track completion rate, cost, and duration (blocked: Implement deft work...)
- Implement overnight loop safety eval: run `deft work --loop --auto-approve-all` against a synthetic repo with 5+ issues overnight; verify no runaway cost, no infinite loops, graceful SIGINT handling, correct issue status transitions; Tier 3 weekly schedule (blocked: Build E2E task battery...)

## orchestration v0.3

- Implement Lead→Foreman messaging: Lead sends messages via `send(foreman_pid, {:lead_message, type, content, metadata})` for types: :status, :decision, :artifact, :contract, :contract_revision, :plan_amendment, :complete, :blocker, :error, :critical_finding
- Implement Lead active steering: Lead reads Runner output after each task completion, evaluates progress against deliverable criteria, sends course corrections to Runner on next spawn; Lead decides when task is done or stuck and reports to Foreman
- Implement Foreman→Lead steering: Foreman sends `send(lead_pid, {:foreman_steering, content})` for course correction; detect conflicting :decision messages from parallel Leads, pause affected Leads, resolve or escalate to user (blocked: Implement Foreman gen_statem...)
- Implement partial dependency unblocking: Foreman watches for {:lead_message, :contract, content, metadata} messages matching dependency `needs`, creates worktree for unblocked Lead, starts Lead with contract details
- Implement contract versioning: :contract_revision Lead message type, Foreman re-steers downstream Leads on revision (blocked: Implement partial dependency unblocking...)
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report (blocked: Implement Foreman→Lead steering..., Implement merge in dependency order...)
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase..., Implement worktree cleanup on Lead crash...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement verification phase...)

## rate-limiter v0.1

- Implement adaptive concurrency: starting at job.initial_concurrency (default 2) Lead slots; scale-up signal (bucket >60% for 30s + zero queued calls → +1 slot up to job.max_leads); scale-down signal (>2 429s/min → -1 slot, minimum 1); send {:rate_limiter, :concurrency_change, new_limit} to Foreman
- Implement cost ceiling: pause job at cost_ceiling - $1.00 buffer; in-flight calls complete (slight overshoot accepted); no new calls dispatched until user approves continued spending

## git-strategy v0.1

- Implement merge in dependency order: when Lead sends {:lead_message, :complete, ...}, Foreman merges Lead branch into deft/job-<job_id>; on conflict, spawn merge-resolution Runner; independent Leads merged in completion order
- Implement post-merge test command: run configurable test command (not hardcoded `mix test`) on merged job branch after each Lead merge to catch semantic conflicts early; on failure, spawn fix-up Runner or flag for user intervention (blocked: Implement merge in dependency order...)
- Implement squash-merge on job complete: after verification passes, squash-merge deft/job-<job_id> into original branch (configurable: job.squash_on_complete, default true); delete job branch; verify no worktrees remain via `git worktree list` (blocked: Implement post-merge test command...)

## filesystem v0.2

- Implement site log programmatic promotion: pattern match on Lead messages — auto-promote contract, decision, correction, critical_finding; promote finding if tagged shared; never promote status or blocker (blocked: Implement Foreman gen_statem...)
- Implement per-Lead cache isolation: start one Deft.Store instance per Lead with DETS at cache/<session_id>/lead-<lead_id>.dets; Lead cleanup deletes its own cache instance (blocked: Implement Lead gen_statem...)
- Implement session-end cache cleanup: on session termination, delete all files under cache/<session_id>/ (blocked: Implement per-Lead cache isolation...)

## issues v0.2

- Implement `deft work`: call ready/0, pick first, set status :in_progress, start Foreman job with issue structured JSON as prompt (context → research, acceptance_criteria → verification targets, constraints → Lead steering), on success set :closed + job_id, on failure set back to :open - Implement `deft work <id>`: same as `deft work` but for a specific issue ID, verify issue exists and is open (blocked: Implement deft work...)
- Implement `deft work --loop`: approve every plan by default (each issue gets plan approval checkpoint); --auto-approve-all flag skips all plan approvals for fully autonomous mode; stop when no ready issues remain, cumulative cost exceeds work.cost_ceiling, or user aborts; re-evaluate unblocked issues between jobs (blocked: Implement deft work...)
- Implement SIGINT handling: catch Ctrl+C, send graceful shutdown to Foreman, wait for current issue status rollback to :open (5-second timeout), then exit; if timeout expires, issue left at :in_progress (detected as stale on next startup) (blocked: Implement deft work --loop...)
