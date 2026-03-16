Study AGENTS.md for guidelines.
Read specd_work_list.md in full — it contains all remaining work items.

Your task is to implement ONE work item from specd_work_list.md, then validate it works.

## Step 1: Pick a work item

- Pick an unblocked item from specd_work_list.md — an item is unblocked if and only if its line does NOT contain the string `(blocked:`. Items without that string are ready to implement regardless of what version or section they're in.

## Step 2: Read the relevant spec

- The section header above the work item tells you which spec it belongs to (e.g. `## auth v0.1` means read the auth spec)
- Read ONLY that spec — do not read other specs. The work item is a summary; the spec has the detail.
- Specs are the source of truth, not existing code
- Only implement work items for specs with status "Ready"

## Step 3: Implement

- If code contradicts the spec, fix the code first (see AGENTS.md)
- Do NOT use TodoWrite — just do the work
- Do NOT do multiple things — ONE thing per iteration

## Step 4: Validate

<!-- Customize: add your project's validation steps here -->
- Run the project's test suite to catch errors
- If there are linting or formatting errors fix them even if they aren't in a file you modified

## Step 5: Record

Log any significant implementation decisions to `specd_decisions.jsonl` — prepend each as a single JSON line (newest first). Use `"source": "implement"` and `"decision_by": "claude"`. Log decisions like choosing one approach over another, discovering a spec gap, or deviating from an expected pattern.

Update tracking files, then commit:

- If the environment variable `SPECD_LOOP` is set, commit automatically.
- Otherwise, present a summary of changes and ask the user for confirmation before committing.

1. Add a line at the TOP of specd_history.md (below the header comment) in the format: `- **spec-name v0.1 (YYYY-MM-DD):** work item text` (use the work item text from specd_work_list.md as the description)
2. Remove the completed item from specd_work_list.md.
3. Check specd_work_list.md for items with `(blocked: ...)` annotations that reference the work you just completed. If the blocker is resolved, remove the `(blocked: ...)` annotation.
4. Commit ALL changes — code, tests, and tracking files (specd_work_list.md, specd_history.md) — in a single commit. Do not commit code separately from tracking updates.
   Output `TASK_COMPLETE: true` when done.

Before declaring LOOP_COMPLETE, re-read specd_work_list.md and list every remaining
item. For each item, check: does the line contain `(blocked:`? If ANY item does
NOT contain `(blocked:`, you are NOT done — pick one and implement it.

Output `LOOP_COMPLETE: true` only if every remaining item in specd_work_list.md
contains `(blocked:` on its line, or the file is empty.
