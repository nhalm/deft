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

## filesystem v0.4

- Change Store async load from `Task.async` to `Task.async_nolink` (store.ex:177): `Task.async` creates a link; if the load task crashes (e.g., DETS iteration error), the linked exit kills the Store GenServer before the `{:DOWN, ...}` handler at line 252 can fire; `Task.async_nolink` preserves the monitor-based error handling that the spec requires (graceful degradation to `:miss` on load failure)
- Fix `resolve_real_path` to use `File.realpath/1` instead of `:file.read_link_all/1` (project.ex:126-133): `:file.read_link_all/1` only resolves the final path component; if an intermediate directory is a symlink (e.g., `/home/nick` → `/Users/nick`), the symlink is not resolved; two paths to the same repo produce different project directories, siloing sessions and cache

## issues v0.5

- Add explicit `handle_job_result({:error, :aborted}, ...)` clause in CLI (cli.ex:2304-2319): non-SIGINT Foreman aborts (`:shutdown` exit) produce `{:error, :aborted}` from `wait_for_job_completion`; this falls through to the generic `{:error, reason}` handler which calls `exit({:shutdown, 1})`; the work loop's graceful abort branch (print "Job aborted", report cost, return `:ok`) is unreachable for non-SIGINT aborts