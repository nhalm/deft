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

- Handle post-merge test failure by removing Lead from tracking and spawning fix-up Runner or flagging user: `handle_test_failure` (foreman.ex:1264-1273) sends a `:critical_finding` but leaves the Lead in `data.leads`, so `all_leads_complete?` never returns true and the job hangs in `:executing` permanently; spec section 3 step 4 requires fix-up Runner or user intervention

## filesystem v0.3

- Fix `generate_site_log_key` to produce stable keys for overwritable entries: currently appends millisecond timestamp to every key (foreman.ex:1349-1354), making all keys unique; spec section 5.4 requires "same key replaces the previous entry" — semantic entries like contracts and decisions should use stable keys (e.g. `"contract-<deliverable_name>"`) so updates overwrite previous values
- Use `File.realpath/1` (or `:file.read_link_all/1`) instead of `Path.expand/1` in `resolve_real_path` (project.ex:126-128): `Path.expand/1` normalizes `~` and relative paths but does not resolve symlinks; two symlinked paths to the same repo produce different encoded project directories, siloing sessions and cache

