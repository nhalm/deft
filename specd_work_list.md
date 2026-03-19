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

## evals v0.3

- Restore all eval test files (test/eval/ is empty again): previous restoration (commit ab28121, decision logged 2026-03-19T21:13:48Z) has regressed; all 26 component tests, fixtures, and support modules are missing; restore from git history and investigate which subsequent commit deleted them to prevent recurrence

## observational-memory v0.3

- Fix `truncate_tool_result` guard to use `String.length` instead of `byte_size` (prompt.ex:279): multi-byte UTF-8 characters cause premature truncation; the guard `byte_size(content) > 2000` should be a character count check, matching the v0.3 spec clarification

## orchestration v0.6

- Fix `/correct` command crash: `write_to_site_log/4` returns `:ok` but line 464 rebinds `data` to that atom; `send_user_message/2` at line 467 then crashes on `:ok.messages` (BadMapError); `write_to_site_log` must return the updated `data` struct, or line 464 must not rebind `data`
- Fix clause ordering: merge_resolution handler (foreman.ex:1031) matches `{:executing, _agent_state}` which swallows tool task results in `{:executing, :executing_tools}` state; `Map.pop(tasks, ref)` returns `{nil, _}` and handler returns `:keep_state_and_data`, preventing tool task handler (foreman.ex:1139) from ever firing; tool results are permanently lost and Foreman hangs
