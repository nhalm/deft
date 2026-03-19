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

- Use `File.realpath/1` (or `:file.read_link_all/1`) instead of `Path.expand/1` in `resolve_real_path` (project.ex:126-128): `Path.expand/1` normalizes `~` and relative paths but does not resolve symlinks; two symlinked paths to the same repo produce different encoded project directories, siloing sessions and cache

