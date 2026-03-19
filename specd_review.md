# Review

## git-strategy

**Finding:** Lead branches not deleted after successful merge — orphaned branches accumulate
**Code:** `handle_test_success` (foreman.ex:1245-1261) calls `cleanup_worktree` which runs `git worktree remove --force` but never deletes the `deft/lead-<id>` branch; no `git branch -d` call exists in the post-merge success path
**Spec:** Section 3 step 5 says "Foreman cleans up the worktree" but doesn't explicitly say "delete the branch". Section 6 (orphan cleanup) targets `deft/lead-*` branches, implying they should not persist after normal completion.
**Options:** (A) Add `git branch -d deft/lead-<id>` after successful merge/test as part of cleanup. (B) Leave as-is and let orphan cleanup handle it at next startup.
**Recommendation:** Option A — deleting the branch after merge is cheap, prevents false positives in orphan cleanup, and matches the intent that completed work is integrated into the job branch.

## issues

**Finding:** `create` does not validate that dependency IDs exist; combined with `is_ready?` treating missing deps as satisfied, `--blocked-by deft-nonexistent` creates an issue that appears immediately unblocked
**Code:** `handle_call({:create, attrs})` (issues.ex:213-247) calls `check_cycle` but never `validate_blocker_exists`; contrast `add_dependency` (issues.ex:340-342) which validates both issue and blocker exist
**Spec:** Section 3 says "Circular dependency detection: on create or update, walk the dependency graph." Does not explicitly require existence validation. `is_ready?` treating missing deps as closed is correct per spec (section 3: "All issues in its dependencies list have status :closed").
**Options:** (A) Add `validate_blocker_exists` to create path, rejecting nonexistent dependency IDs. (B) Leave as-is — `is_ready?` handles the edge case by treating missing deps as satisfied, which is arguably the right semantic (the blocker is gone, so it's not blocking). (C) Add a warning on create when dependency IDs don't match existing issues.
**Recommendation:** Option A for consistency with `add_dependency`, plus a warning in Option C style. Users specifying `--blocked-by` intend a real dependency; silently accepting garbage IDs is confusing.

