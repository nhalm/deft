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

- Remove duplicate `Store.start_link` call from `Foreman.init` (foreman.ex:214-221): Store is already started as a child of `Deft.Job.Supervisor` (supervisor.ex:56-68) with the same `{:sitelog, job_id}` name; the second start crashes the Foreman with a match error on `{:error, {:already_started, pid}}`
- Start Leads via `LeadSupervisor.start_lead/2` instead of calling `Lead.start_link/1` directly (foreman.ex:2041): Leads currently bypass the DynamicSupervisor and run unsupervised
- Implement per-Lead `Deft.Job.Lead.Supervisor` (one_for_one) containing the Lead gen_statem and RunnerSupervisor as siblings per spec section 1; currently `Task.Supervisor.start_link` is called directly in `start_lead` (foreman.ex:2022), leaving the RunnerSupervisor as an orphaned process
- Enforce Runner timeout in Lead: after spawning a Runner via `spawn_runner`, call `Process.send_after(self(), {:runner_timeout, task_ref}, timeout)` using the `job.runner_timeout` config value (default 300_000ms per spec section 8); currently no timeout is enforced (lead.ex:703-733)
- Fix `determine_completed_deliverables` key parsing (foreman.ex:2474-2509): `generate_site_log_key(:complete, metadata)` produces `"complete-<session_id>-<deliverable_name>-<timestamp>"` but `String.split(key, "-", parts: 3)` splits at the first two hyphens, giving wrong lead_id when session_id contains hyphens (UUIDs); use a delimiter that doesn't appear in UUIDs or store lead_id as a separate field
- Enforce `job.max_leads` config (default 5) in `get_ready_deliverables` or `start_ready_leads`: currently all ready deliverables are started simultaneously with no cap (foreman.ex:1992-2003)
- Spawn merge-resolution Runner on merge conflict instead of discarding work: `handle_merge_conflict` (foreman.ex:1288-1303) sends a `:critical_finding` and deletes the Lead's worktree, permanently losing the Lead's work; spec section 3.4 requires spawning a merge-resolution Runner to resolve conflicts

