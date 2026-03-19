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

- Implement verification phase: after all Leads complete, Foreman spawns verification Runner (full test suite + reviews modified files); on pass, trigger squash-merge; on fail, identify responsible Lead and report
- Implement job cleanup: Foreman cleans all worktrees on completion/failure/abort, archives job files to ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on Lead crash, Foreman cleans that Lead's worktree immediately (blocked: Implement verification phase...)
- Implement job persistence and resume: store sitelog.dets, plan.json, foreman_session.jsonl, lead_<id>_session.jsonl at ~/.deft/projects/<path-encoded-repo>/jobs/<job_id>/; on resume, read site log + plan.json, start fresh Leads for incomplete deliverables (blocked: Implement verification phase...)

## issues v0.2

- Implement Edit option in draft confirmation: currently prints "Edit mode not yet implemented" and returns :ok (cli.ex:1729-1731); spec section 5.1 requires reopening conversational flow with existing fields pre-populated
- Wire cost tracking in deft work loop: run_work_on_issue_with_cost always returns {:ok, 0.0} (cli.ex:1912-1918); cost ceiling check at cli.ex:1875 never triggers; must read actual cost from RateLimiter after job completes

