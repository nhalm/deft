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

## orchestration v0.4

- Fix `config.work_cost_ceiling` KeyError in `Job.Supervisor.init/1` (supervisor.ex:83): the `.` accessor on the plain `agent_config` map raises KeyError because the CLI (cli.ex:2058-2078) does not include a `work_cost_ceiling` key. Either add `work_cost_ceiling` to the CLI config map from `config.work_cost_ceiling`, or use `Map.get(config, :work_cost_ceiling, 10.0)` in the supervisor.

