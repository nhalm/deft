Study AGENTS.md for guidelines.

Your task is to process specd_review.md — move approved items into specd_work_list.md, then clear them from specd_review.md.

PROCESS:

1. Read specd_review.md. If the file is empty or doesn't exist, output `REVIEW_INTAKE_COMPLETE: true` and stop.
2. For each finding in specd_review.md:
   - Read the referenced spec for context
   - Create a concrete, actionable work item in specd_work_list.md under the correct `## spec-name vX.Y` section
   - If the finding requires a spec change, update the spec: bump version, add a changelog entry with human-readable summary, then add the work item to specd_work_list.md under the new version
3. After all items are moved, clear the processed entries from specd_review.md.
4. Output `REVIEW_INTAKE_COMPLETE: true` when done.

DECISION LOGGING:

Log every review outcome to `specd_decisions.jsonl` — prepend each as a single JSON line (newest first). Use `"source": "review-intake"`. For `decision_by`, use the human's name from `git config user.name` (the human made the call by keeping or deleting the item in specd_review.md).

Decisions to log:
- Promoting a finding to a work item (and the reasoning from the review entry)
- Updating a spec based on a review finding

COMMITTING:

After processing all findings, commit all changed files together in a single commit. This includes spec files, `specs/README.md`, `specd_work_list.md`, `specd_review.md`, and `specd_decisions.jsonl`.

- If the environment variable `SPECD_LOOP` is set, commit automatically.
- Otherwise, present a summary of changes and ask the user for confirmation before committing.

RULES:

- Each work item must be a small, single unit of work — one agent can complete it in one iteration
- If a work item depends on another, add `(blocked: dependency description)` at the end
- Use the exact specd_work_list.md format: section headers are `## spec-name vX.Y`, items are `- description`
- Do NOT implement anything — only populate specd_work_list.md
