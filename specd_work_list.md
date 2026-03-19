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

## orchestration v0.3

- Implement Deft.Job.Supervisor (one_for_one) with Store, RateLimiter, Foreman, and LeadSupervisor as children, using `:temporary` restart for all child specs per spec section 1
- Fix `determine_completed_deliverables` site log key parsing: `generate_site_log_key(:complete, metadata)` uses `Map.get(metadata, :key, "entry")` as base_key, but completion metadata has `:lead_id` and `:deliverable` — not `:key`; all completion entries get key `"complete-entry-<ts>"`, so resume always parses `lead_id = "entry"` and finds zero completed deliverables (foreman.ex:1318-1323, 2430-2457)
- Fix merge conflict/error paths to remove Lead from tracking and clean up worktree: `handle_lead_merge` returns unchanged `data` on `{:ok, :conflict, ...}` and `{:error, reason}` (foreman.ex:1201-1208); Lead stays in `data.leads`, worktree is leaked, `all_leads_complete?` never returns true, job hangs in `:executing` permanently

## git-strategy v0.1

- Fix `run_post_merge_tests` to run tests on the job branch: currently runs tests via `File.cd!(working_dir, ...)` where `working_dir` is the main repo root, not a worktree checked out to `deft/job-<job_id>` (job.ex:474-481); merged code on the job branch is never tested, defeating post-merge test purpose
- Fix abort and verification-failure paths to delete job branch: abort handler (foreman.ex:485-506) and verification failure handler (foreman.ex:823-850) clean up worktrees but never delete `deft/job-<job_id>` branch; `job_keep_failed_branches` config field exists in Deft.Config but is never read anywhere; orphaned job branches accumulate

## filesystem v0.3

- Fix resolve_git_root for normal (non-worktree) repos (REGRESSION): `git rev-parse --git-common-dir` returns relative `.git`, `Path.dirname(".git")` returns `"."`, all normal repos map to same `~/.deft/projects/.` directory (project.ex:131-139); must expand relative path against working dir before dirname; previously fixed per specd_history but fix has regressed

## issues v0.2

- Fix SIGINT abort return value in work loop: `handle_job_result({:error, :sigint_shutdown}, ...)` returns `:ok` (cli.ex:2204), which `run_work_on_issue` maps to `{:ok, cost}` (cli.ex:2069); loop at cli.ex:1955 matches `{:ok, job_cost}` and continues to next issue instead of stopping; should return `{:error, :aborted}` to match the loop's stop condition at cli.ex:1963

