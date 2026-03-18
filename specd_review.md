# Review

## filesystem

**Finding:** ETS table created as `:public` instead of spec-required `:protected`
**Code:** `store.ex:170` creates ETS with `[:set, :public]`. Comment explains the async load task (spawned via `Task.async` at line 174) needs to write during initialization, and it runs in a separate process.
**Spec:** Section 3 startup step 2 and section 5.5 require `:protected` (owner-write, other-read) to prevent Leads from bypassing GenServer write access control.
**Options:** (a) Load DETS synchronously in init (simpler but blocks GenServer startup), (b) Spawn load task then transfer ETS ownership back, (c) Have load task send data back to GenServer to insert, (d) Accept `:public` and update spec — rely on API convention for access control.
**Recommendation:** Option (c) — load task collects entries and sends them to GenServer via message, GenServer inserts into `:protected` ETS. Preserves async loading without exposing the table.

## skills

**Finding:** Spec section 4.2 shows commands listed with descriptions (`- /commit — Generate a commit message and commit`), but commands have no mechanism to provide descriptions
**Code:** `system_prompt.ex:147` formats commands as `"- /#{entry.name}"` (no description). `registry.ex:209` sets `description: nil` for commands. Command files are plain markdown with no frontmatter per spec section 1.1.
**Spec:** Section 4.2 shows commands with descriptions in the system prompt listing. Section 1.1 says "No frontmatter, no metadata" for commands. These are contradictory.
**Options:** (a) Extract first heading or first line of command file as description, (b) Allow optional minimal frontmatter for commands (just description), (c) Update spec to show commands without descriptions, (d) Use filename-derived descriptions.
**Recommendation:** Option (a) — extract the first non-empty line of the command markdown as the description. Minimal change, no frontmatter needed, and authors naturally write a title/summary as the first line.
