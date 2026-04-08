# memory Agent Guidelines

## Spec Authority

**Specs are prescriptive, not descriptive.** The spec defines what code MUST do.

- **Spec is source of truth.** If code contradicts the spec, the code is wrong — refactor it.
- **Read the full spec on version changes.** When the spec version is newer than specd_history.md, re-read the entire spec — not just the changelog. The changelog summarizes what changed, but context lives in the full spec.
- **Don't build on broken foundations.** If existing code uses the wrong model (e.g., wrong ID scheme, wrong data flow), fix it first. Don't add new features on top of incorrect code.
- **Spec index:** `specs/README.md` lists all specifications organized by phase. Only specs with status "Ready" should be implemented.
- **Changelogs are immutable.** When creating new changelog entries, old entries never change.

## Audit Discipline

**Zero findings is a valid and expected outcome.** An audit that confirms correctness is successful — do not manufacture findings to justify the work.

**The bar for a finding is: will this cause a bug in production?** Not "could this theoretically be a problem under unlikely conditions" — will it actually break?

Before reporting a finding:
- **Read the actual code, not just the spec.** Findings based on spec text alone are unreliable. The code is the ground truth — if the code is correct, there is no finding.
- **Ignore spec changelogs during audits.** Changelogs are historical records of past changes. The spec body (Overview, Specification, Notes) defines current requirements. Auditing against changelog entries produces phantom findings about already-resolved issues.
- **Check if it's actually reachable.** Trace the code path. If it requires multiple unlikely conditions to trigger, and existing safety nets (timeouts, cost ceilings, human abort) bound the impact, it's not a finding.
- **Check if the spec section is prescriptive.** "Notes", "Resolved questions", and "Design decisions" sections are commentary, not requirements. Don't flag unimplemented commentary.
- **Check if behavior is handled by LLM choice.** If the spec describes behavior that the LLM naturally produces via its tool set and prompt (e.g., choosing not to orchestrate for simple tasks), the absence of a dedicated code path is not a gap.
- **Check if idle processes are actually harmful.** An empty supervisor under `one_for_one` that gets cleaned up when its parent stops is not a leak. A process consuming no resources is not worth a finding.
- **Don't flag missing safety nets when other safety nets exist.** A missing timeout is low-priority when cost ceilings and human abort are available.

## Loop System

The autonomous loop is defined in `loop.sh`. Commands live in `.claude/commands/`:

| Command          | Purpose                                                                        |
| ---------------- | ------------------------------------------------------------------------------ |
| `/specd:implement`     | Pick one unblocked work item, implement it, validate, record completion        |
| `/specd:audit`         | 3-phase spec-vs-code audit. Writes findings to specd_work_list.md and specd_review.md |
| `/specd:review-intake` | Process specd_review.md items into specd_work_list.md                                 |
| `/specd:full-audit`    | Like audit but covers Ready AND Implemented specs — demotes Implemented specs with findings |

## specd_work_list.md (Remaining Work)

The single execution queue for all work — spec implementations, audit findings, and promoted review items. **Read it in full** at the start of each iteration — it is kept small. Pick an unblocked item, implement it, then move it to specd_history.md.

## specd_history.md (Done Log)

specd_history.md is the archive of completed work in reverse chronological order (newest first). It does NOT contain remaining items — those live in specd_work_list.md.

Each entry is a single line: `- **spec-name v0.1 (YYYY-MM-DD):** description`. New entries go at the top of the file, below the header comment.

**Never read specd_history.md in full — it can get large.** Use `Grep` to search for specific specs or dates when checking for duplicates.

## specd_review.md (Human Decisions)

Ambiguous findings from audits that need human judgment. Items sit here until the human reviews them. On next loop start, `/specd:review-intake` promotes remaining items to specd_work_list.md (human deletes items they disagree with before restarting).

## specd_decisions.jsonl (Decision Log)

Machine-readable log of decisions made during planning, audits, implementation, and review. One JSON object per line, newest first. **Never read in full** — use `Grep` or `jq` to query.

Every significant decision must be logged: scoping choices, spec changes, audit judgments, review outcomes. Each entry records who decided (AI or human via git config), which command produced it, and which files are involved.

Entry format:
```json
{"date_time":"2025-01-15T14:30:00Z","spec":"auth","version":"v0.1","source":"audit","decision_by":"claude","summary":"Kept argon2 over spec's bcrypt","reasoning":"argon2 is current best practice","files":{"specs":["specs/auth.md"],"source_code":["src/auth.js"],"other":["specd_work_list.md"]}}
```

Fields:
- `date_time` — ISO 8601 UTC
- `spec` — spec name (without path or extension)
- `version` — spec version at time of decision, or `null` if not version-specific
- `source` — command that produced it: `plan`, `audit`, `full-audit`, `review-intake`, `implement`
- `decision_by` — `"claude"` for AI decisions, or the human's name from `git config user.name`
- `summary` — one-line description of the decision
- `reasoning` — why this decision was made
- `files.specs` — spec files affected
- `files.source_code` — source code files affected
- `files.other` — other files affected (work list, history, etc.)

## Build & Test

- Run `make check` for linting and formatting, `make test` for the test suite
- Validate with the full test suite, not just unit tests. If integration tests fail, that's a real failure — do not dismiss them.

## Conventions

- Follow patterns in existing code for naming, structure, and style
- Match the language and framework conventions of the project
- See specs/ for directory layout and project structure specs

### Interfaces and Dependencies

- **Use interfaces for external dependencies.** Database access, HTTP clients, external services — anything that crosses a boundary.
- **Mock at boundaries, not internals.** Mock the interface, not implementation details.
- **Dependency injection over globals.** Pass dependencies explicitly rather than importing singletons.
