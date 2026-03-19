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

- Wire Lead call_llm to use LLM provider through RateLimiter: currently a no-op stub returning make_ref() (lead.ex:622-626); Lead steering cannot produce real LLM output
- Add RateLimiter.reconcile call after Runner LLM response: Runner never calls reconcile/4 after getting API response; TPM bucket tokens are deducted but never credited back, causing bucket to drain faster than actual usage (runner.ex:157-172)
- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report (blocked: Wire Lead call_llm...)
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement verification phase...)

## git-strategy v0.1

- Fix stash prompt to actually stash: user answering "yes" to stash prompt prints "Please run: git stash" and returns {:error, :dirty_working_tree} (job.ex:116-120); should call `git stash` programmatically and continue job creation
- Fix run_post_merge_tests :timeout option: System.cmd/3 does not support a :timeout option (job.ex:418); the unsupported option causes FunctionClauseError or is silently ignored; post-merge test timeout is not enforced; use Task.async + Process.send_after pattern instead
- Fix merge_lead_branch to not checkout on main working tree: git checkout in File.cd!(working_dir) (job.ex:310-315) conflicts with worktrees that may have the job branch checked out; use `git merge` in a worktree or `git merge-tree` instead

## issues v0.2

- Fix auto_approve config key mismatch and inversion: CLI writes `auto_approve_plans: !flags[:auto_approve_all]` (cli.ex:1965) but Foreman reads `Map.get(data.config, :auto_approve_all, false)` (foreman.ex:1174); key names don't match AND value is inverted; --auto-approve-all flag has no effect on plan approval
- Implement Edit option in draft confirmation: currently prints "Edit mode not yet implemented" and returns :ok (cli.ex:1729-1731); spec section 5.1 requires reopening conversational flow with existing fields pre-populated
- Wire cost tracking in deft work loop: run_work_on_issue_with_cost always returns {:ok, 0.0} (cli.ex:1912-1918); cost ceiling check at cli.ex:1875 never triggers; must read actual cost from RateLimiter after job completes

