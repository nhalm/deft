# Coordination Protocol

| | |
|--------|----------------------------------------------|
| Version | 0.17 |
| Status | Ready |
| Last Updated | 2026-04-10 |

## Changelog

### v0.17 (2026-04-10)
- Extracted from orchestration.md §7 with updated naming

## Overview

The coordination protocol defines how Coordinators communicate via OTP messages and how the site log captures curated job knowledge.

**Scope:**
- Message format and types
- Deft.Store site log write policy

**Dependencies:**
- [coordinator.md](coordinator.md) — Foreman.Coordinator (primary message handler)
- [lead.md](lead.md) — Lead.Coordinator (message sender)
- [../filesystem.md](../filesystem.md) — Deft.Store details

## Specification

### 1. Message Format

All Coordinator↔Coordinator communication happens via Erlang process messages.

**Lead.Coordinator → Foreman.Coordinator:** `send(coordinator_pid, {:lead_message, type, content, metadata})`
**Foreman.Coordinator → Lead.Coordinator:** `send(lead_coordinator_pid, {:coordinator_steering, content})`

### 2. Message Types

| Type | Direction | Purpose |
|------|-----------|---------|
| `plan` | Foreman.Coordinator→broadcast | Work plan with deliverables and DAG |
| `finding` | Runner→Lead→Foreman | Research result. Lead may tag as `shared` — shared findings are auto-promoted to site log. |
| `decision` | Lead.Coordinator→Foreman.Coordinator | Choice made with rationale |
| `contract` | Lead.Coordinator→Foreman.Coordinator | Interface definition satisfying a dependency |
| `contract_revision` | Lead.Coordinator→Foreman.Coordinator | Updated contract |
| `artifact` | Lead.Coordinator→Foreman.Coordinator | File created or modified |
| `status` | Lead.Coordinator→Foreman.Coordinator | Progress update |
| `blocker` | Lead.Coordinator→Foreman.Coordinator | Stuck, needs Foreman input |
| `steering` | Foreman.Coordinator→Lead.Coordinator | Guidance |
| `plan_amendment` | Lead.Coordinator→Foreman.Coordinator | Request for plan change |
| `complete` | Lead.Coordinator→Foreman.Coordinator | Deliverable finished |
| `error` | Any→Foreman.Coordinator | Something went wrong |
| `cost` | RateLimiter→Foreman.Coordinator | Cost checkpoint (sent as `{:rate_limiter, :cost, amount}`) |
| `correction` | User→Foreman (via `/correct`) | User course-correction — auto-promoted to site log |
| `critical_finding` | Lead.Coordinator→Foreman.Coordinator | Important finding — auto-promoted to site log |

### 3. Priority Classification

**High-priority (flush buffer immediately):**
- `:blocker`, `:complete`, `:error`, `:critical_finding`

**Low-priority (buffered and coalesced):**
- `:status`, `:artifact`, `:decision`, `:finding`, `:contract`, `:contract_revision`

### 4. Deft.Store Site Log

The Foreman.Coordinator maintains a `Deft.Store` instance (ETS+DETS) for curated job knowledge.

**Write policy:** The Foreman.Coordinator writes based on incoming messages. Auto-promoted types: `contract`, `decision`, `correction`, `critical_finding`. Other types written at the Coordinator's discretion.

**Read access:** Leads can read from the site log to access contracts, decisions, and other curated knowledge.

## References

- [coordinator.md](coordinator.md) — Foreman.Coordinator
- [lead.md](lead.md) — Lead.Coordinator
- [../filesystem.md](../filesystem.md) — Deft.Store
