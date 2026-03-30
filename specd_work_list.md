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

## orchestration v0.7

- Fix research result collection Task ownership violation (foreman.ex:216-219,1065-1073): research tasks are owned by the Foreman process but `collect_research_results` calls `Task.yield` from a separate collector task — `Task.yield` raises or hangs because caller is not the task owner
- Fix Lead crash handler treating crashed Leads as successfully completed (foreman.ex:1017-1020): when a crashed Lead is the last in `started_leads`, Foreman transitions to `:verifying` with missing deliverables — should not count a crash as completion
