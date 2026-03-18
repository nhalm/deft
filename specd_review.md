# Review

## filesystem

**Finding:** ETS table created as `:public` instead of spec-required `:protected`
**Code:** `store.ex:170` creates ETS with `[:set, :public]`. Comment explains the async load task (spawned via `Task.async` at line 174) needs to write during initialization, and it runs in a separate process.
**Spec:** Section 3 startup step 2 and section 5.5 require `:protected` (owner-write, other-read) to prevent Leads from bypassing GenServer write access control.
**Options:** (a) Load DETS synchronously in init (simpler but blocks GenServer startup), (b) Spawn load task then transfer ETS ownership back, (c) Have load task send data back to GenServer to insert, (d) Accept `:public` and update spec — rely on API convention for access control.
**Recommendation:** Option (c) — load task collects entries and sends them to GenServer via message, GenServer inserts into `:protected` ETS. Preserves async loading without exposing the table.
