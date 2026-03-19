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

- Implement issue→plan diagnostic eval: verify that structured issue fields (context, acceptance_criteria, constraints) flow correctly into Foreman research/planning/verification phases; 20 iterations, 75% pass rate
- Build E2E task battery: create 3 synthetic repos (minimal Phoenix app, CLI tool, library with tests) with pre-defined issues; implement test harness that runs `deft work` against each repo and verifies acceptance criteria are met; track completion rate, cost, and duration
- Implement overnight loop safety eval: run `deft work --loop --auto-approve-all` against a synthetic repo with 5+ issues overnight; verify no runaway cost, no infinite loops, graceful SIGINT handling, correct issue status transitions; Tier 3 weekly schedule (blocked: Build E2E task battery...)

## orchestration v0.3

- Implement Foreman→Lead steering: Foreman sends `send(lead_pid, {:foreman_steering, content})` for course correction; detect conflicting :decision messages from parallel Leads, pause affected Leads, resolve or escalate to user
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report (blocked: Implement Foreman→Lead steering..., Implement merge in dependency order...)
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase..., Implement worktree cleanup on Lead crash...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement verification phase...)

