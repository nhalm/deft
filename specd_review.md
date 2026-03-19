# Review

## git-strategy

**Finding:** Lead branches not deleted after successful merge — orphaned branches accumulate
**Code:** `handle_test_success` (foreman.ex:1245-1261) calls `cleanup_worktree` which runs `git worktree remove --force` but never deletes the `deft/lead-<id>` branch; no `git branch -d` call exists in the post-merge success path
**Spec:** Section 3 step 5 says "Foreman cleans up the worktree" but doesn't explicitly say "delete the branch". Section 6 (orphan cleanup) targets `deft/lead-*` branches, implying they should not persist after normal completion.
**Options:** (A) Add `git branch -d deft/lead-<id>` after successful merge/test as part of cleanup. (B) Leave as-is and let orphan cleanup handle it at next startup.
**Recommendation:** Option A — deleting the branch after merge is cheap, prevents false positives in orphan cleanup, and matches the intent that completed work is integrated into the job branch.

