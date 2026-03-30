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

## orchestration v0.7

- Create `Deft.Job.Foreman` gen_statem with 7 pure orchestration states (`:asking`, `:planning`, `:researching`, `:decomposing`, `:executing`, `:verifying`, `:complete`) — no agent loop, no streaming, no tool execution
- Create `Deft.Job.ForemanAgent` module that starts a standard `Deft.Agent` with Foreman-specific system prompt and OM enabled
- Implement 7 ForemanAgent orchestration tools (`ready_to_plan`, `request_research`, `submit_plan`, `spawn_lead`, `unblock_lead`, `steer_lead`, `abort_lead`) as thin wrappers that `send(foreman_pid, {:agent_action, action, payload})` and return `:ok` (blocked: Create Deft.Job.Foreman, Create Deft.Job.ForemanAgent)
- Implement `:asking` phase in Foreman: relay ForemanAgent text responses to user as questions, relay user answers back to ForemanAgent as prompts, transition to `:planning` on `{:agent_action, :ready_to_plan}` (blocked: Create Deft.Job.Foreman, Create Deft.Job.ForemanAgent)
- Wire Foreman `handle_info` to process `{:agent_action, ...}` messages from ForemanAgent — dispatch to research spawning, plan presentation, Lead lifecycle, and steering (blocked: Implement 6 ForemanAgent orchestration tools)
- Implement Foreman→ForemanAgent prompt flow: Foreman calls `Deft.Agent.prompt/2` with structured context (research results, Lead progress, contracts, user messages) (blocked: Create Deft.Job.Foreman, Create Deft.Job.ForemanAgent)
- Create `Deft.Job.Lead` gen_statem with 4 orchestration states (`:planning`, `:executing`, `:verifying`, `:complete`) — no agent loop
- Create `Deft.Job.LeadAgent` module that starts a standard `Deft.Agent` with Lead-specific system prompt, read-only tools + Lead tools, OM enabled
- Implement 4 LeadAgent tools (`spawn_runner`, `publish_contract`, `report_status`, `request_help`) as thin wrappers that `send(lead_pid, {:agent_action, action, payload})` (blocked: Create Deft.Job.Lead, Create Deft.Job.LeadAgent)
- Wire Lead `handle_info` to process `{:agent_action, ...}` messages from LeadAgent — dispatch to Runner spawning, contract publishing, Foreman reporting, blocker escalation (blocked: Implement 4 LeadAgent tools)
- Implement Lead→LeadAgent prompt flow: Lead calls `Deft.Agent.prompt/2` with deliverable assignment, Runner results, and Foreman steering (blocked: Create Deft.Job.Lead, Create Deft.Job.LeadAgent)
- Update `Deft.Job.Supervisor` to start ForemanAgent + its ToolRunner as separate children alongside the Foreman (blocked: Create Deft.Job.ForemanAgent)
- Update `Deft.Job.Lead.Supervisor` to start LeadAgent + its ToolRunner as separate children alongside the Lead (blocked: Create Deft.Job.LeadAgent)
- Implement single-agent fallback: when Foreman detects simple task, configure ForemanAgent with full tool set (read, write, edit, bash, grep, find, ls) and skip orchestration (blocked: Implement Foreman→ForemanAgent prompt flow)
- Implement Foreman forwarding of Lead progress to ForemanAgent: on receiving `{:lead_message, ...}`, format as structured prompt and call `Deft.Agent.prompt/2` (blocked: Wire Foreman handle_info)
- Implement Lead injection of Foreman steering: on receiving `{:foreman_steering, content}`, format as prompt and call `Deft.Agent.prompt/2` on LeadAgent (blocked: Wire Lead handle_info)
- Remove old tuple-state Foreman implementation (the fused orchestrator+agent gen_statem) and replace with new split architecture (blocked: all above items)
- Remove old tuple-state Lead implementation and replace with new split architecture (blocked: all above items)

## harness v0.3

- Add `parent_pid` option to `Deft.Agent.start_link/1` — stored in agent data, passed through to ToolContext on tool execution
- Add `Deft.Agent.prompt/2` public API for sending prompts to an agent from an external process (orchestrator) — returns `:ok`, agent processes asynchronously
- Ensure `Deft.Agent` broadcasts events via Registry in both standalone and sub-agent modes so orchestrators and web UI can subscribe

## sessions v0.7

- Update `Deft.Session.Store` to support writing agent sessions to job-scoped paths (`jobs/<job_id>/foreman_session.jsonl`, `jobs/<job_id>/lead_<id>_session.jsonl`) in addition to user session paths
- Ensure session listing (`deft issue list`, web UI picker) only returns user sessions, not agent sessions

## rate-limiter v0.3

- Update `RateLimiter.request/4` priority parameter to accept `:foreman_agent`, `:lead_agent`, `:runner` atoms instead of `:foreman`, `:lead`, `:runner`
