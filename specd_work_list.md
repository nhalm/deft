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

## filesystem v0.3

- Fix resolve_git_root for normal (non-worktree) repos (REGRESSION): `git rev-parse --git-common-dir` returns relative `.git`, `Path.dirname(".git")` returns `"."`, all normal repos map to same `~/.deft/projects/.` directory (project.ex:131-139); must expand relative path against working dir before dirname; previously fixed per specd_history but fix has regressed

## issues v0.2

- Fix SIGINT abort return value in work loop: `handle_job_result({:error, :sigint_shutdown}, ...)` returns `:ok` (cli.ex:2204), which `run_work_on_issue` maps to `{:ok, cost}` (cli.ex:2069); loop at cli.ex:1955 matches `{:ok, job_cost}` and continues to next issue instead of stopping; should return `{:error, :aborted}` to match the loop's stop condition at cli.ex:1963

