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

## git-strategy v0.1

- Capture original branch at job creation time and store in Foreman data: `Map.get(data.config, :original_branch, "main")` at foreman.ex:900 always returns "main" because `:original_branch` is never stored; squash-merge always targets "main" regardless of user's actual branch

## issues v0.3

- Pass `compaction_days` config to `Issues.start_link` in `IssueCreate.ensure_issues_started/0` (issue_create.ex:173): calls `Issues.start_link()` with no args, ignoring user's `issues.compaction_days` config; closed issues compacted at 90 days regardless of setting

