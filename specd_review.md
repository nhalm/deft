# Review

## orchestration v0.5

**Finding:** User corrections are never auto-promoted to the site log. The `process_lead_message(:correction, ...)` handler (foreman.ex:1959) is dead code — it only fires on `{:lead_message, :correction, ...}` messages, which no process ever sends. User input arrives via `Foreman.prompt/2` → `{:cast, {:prompt, text}}` → fed directly into LLM turn without site log write.

**Code:** `lib/deft/job/foreman.ex:1959` — `process_lead_message(:correction, ...)` writes to site log but is unreachable. User prompts handled at `foreman.ex:457` with no correction classification or promotion.

**Spec:** Section 6.2 table: `correction | User→Foreman | User course-correction — auto-promoted to site log`

**Options:** (1) Classify user prompts as corrections via LLM analysis before site log promotion; (2) Auto-promote all mid-job user prompts to site log; (3) Add an explicit `/correct` command that routes through the correction handler; (4) Remove the spec requirement if corrections aren't needed for job resume.

**Recommendation:** Option 3 — explicit `/correct` command is simplest and most predictable. Users rarely need implicit correction classification, and an explicit command makes intent clear.
