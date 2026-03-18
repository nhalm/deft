# Skills & Commands

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Ready |
| Last Updated | 2026-03-18 |

## Changelog

### v0.3 (2026-03-18)
- Added command descriptions: extract the first non-empty line of the command markdown file as the description.
- Updated section 4.2 (system prompt integration) to show commands with descriptions in the listing.
- Updated section 1 (command format) to specify description extraction mechanism.

### v0.2 (2026-03-16)
- Auto-selection: the agent can now suggest and auto-invoke skills when contextually appropriate. Removed "explicitly rejected" language.
- YAML parsing: specified `String.split` strategy on first `\n---\n`; prohibited `YamlElixir.read_all_from_string`; defined behavior for files missing the `---` separator.
- Error handling: skill YAML parse failures and missing required fields are skipped with a warning; missing directories treated as empty.
- Registry: `load_definition/1` must use `Agent.get_and_update/2` to avoid read/cache race conditions.
- Registry scope: clarified application-global registry vs. project-local `.deft/skills/`; project skills re-scanned each session.
- Namespace: simplified skill/command same-name rules — single namespace, skill wins at same cascade level, normal cascade across levels.

### v0.1 (2026-03-16)
- Initial spec — skills (structured, progressively-loaded capabilities) and commands (simple prompt injection), three-level cascade (built-in → global → project), manifest-based registry, slash command invocation.

## Overview

Skills and commands are Deft's extensibility system. They let users and the project define reusable capabilities that the agent can invoke on demand.

**Commands** are the simple case: a markdown file whose contents get injected as a user message when invoked via slash command. No logic, no structure — just text.

**Skills** are the rich case: structured capabilities with a YAML manifest (name, description, version) and a full definition (detailed prompt/instructions). Manifests are loaded at startup so the agent knows what's available. Full definitions are loaded on demand when invoked, keeping context window usage minimal.

Both exist at three levels with cascade: built-in (bundled with Deft), global (`~/.deft/`), and project (`.deft/`). Project overrides global overrides built-in when names collide.

Skills and commands can be invoked in three ways: the user explicitly types a slash command (`/review`, `/commit`); the agent suggests a skill in prose ("you might want to run /review"); or the agent auto-invokes a skill when clearly appropriate based on context. The agent sees skill manifests (name + description) in its system prompt, which is sufficient for it to decide when to use a skill, just as it decides when to use any tool.

**Scope:**
- Skill manifest format and full definition format
- Command format
- Directory layout and cascade rules
- Registry: discovery, loading, lookup
- Invocation: slash command dispatch, agent suggestion, agent auto-invocation, context injection
- Progressive loading (manifest at boot, full definition on invoke)

**Out of scope:**
- Defining specific built-in skills (each skill is its own concern)
- Tool permissions per skill (future)
- Skill marketplace / sharing (future)

**Dependencies:**
- [sessions.md](sessions.md) — CLI interface, system prompt assembly
- [harness.md](harness.md) — agent loop, slash command dispatch

## Specification

### 1. Commands

#### 1.1 Format

A command is a markdown file. The filename (minus `.md` extension) is the command name. The file's contents are injected verbatim as a user message when the command is invoked.

```
commit.md → /commit
pr.md     → /pr
test.md   → /test
```

No frontmatter, no metadata. The file is the prompt.

**Command descriptions:** The first non-empty line of the markdown file is extracted as the command's description. This line is shown in the system prompt listing and help text. The full file contents (including this line) are injected as the user message when the command is invoked.

#### 1.2 Directory Layout

```
# Built-in (bundled with Deft binary)
<app>/priv/commands/
  commit.md
  pr.md

# Global (user-created)
~/.deft/commands/
  my-workflow.md

# Project (project-specific)
.deft/commands/
  test.md
  deploy.md
```

#### 1.3 Invocation

When the user types `/commit`:
1. Look up `commit` in the command registry
2. Read the file contents
3. Inject as a user message in the current conversation
4. The agent processes it like any other user message

### 2. Skills

#### 2.1 Manifest Format

Skills are defined in YAML files. The manifest section is loaded at startup; the definition section is loaded on demand.

```yaml
# ~/.deft/skills/review.yaml
name: review
description: Perform a comprehensive code review of staged changes
version: "1.0"

---

# Everything below the YAML document separator is the full definition.
# Loaded only when the user invokes /review.

You are performing a code review of the currently staged changes.

## Steps

1. Run `git diff --cached` to see staged changes
2. For each file, analyze:
   - Correctness: bugs, logic errors, edge cases
   - Style: naming, formatting, idiomatic patterns
   - Security: injection, auth, data exposure
3. Provide a summary with findings grouped by severity

## Tools

You have access to: Read, Grep, Bash
```

The YAML front matter (above the `---` separator) is the manifest. Everything after the separator is the full definition — treated as a markdown prompt.

**Parsing strategy:** Split the file content on the first occurrence of `\n---\n` using `String.split(content, "\n---\n", parts: 2)`. Parse only the first part with YamlElixir. Treat the remainder as raw text (the full definition). Do NOT use `YamlElixir.read_all_from_string` — it interprets `---` as a YAML document separator.

**Files missing the `---` separator:** Treated as manifest-only (no definition). The skill appears in listings but cannot be invoked.

#### 2.2 Manifest Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Slash command name (alphanumeric + hyphens) |
| `description` | yes | One-line description shown in help/listings |
| `version` | no | Semver string for tracking changes |

#### 2.3 Directory Layout

```
# Built-in (bundled with Deft binary)
<app>/priv/skills/
  review.yaml
  explain.yaml

# Global (user-created)
~/.deft/skills/
  deploy-check.yaml

# Project (project-specific)
.deft/skills/
  migrate.yaml
```

#### 2.4 Invocation

A skill can be invoked in three ways:

1. **Explicit:** The user types `/review` as a slash command.
2. **Suggested:** The agent suggests a skill in its prose response (e.g., "you might want to run /review"). The user then decides whether to invoke it.
3. **Auto-invoked:** The agent invokes a skill directly when clearly appropriate based on context. The agent emits a `use_skill` tool call with the skill name as the argument. The harness intercepts this tool call, loads the full definition from the Registry, injects it into context, and continues the agent loop. This is the same mechanism as explicit invocation — the only difference is who initiates it (agent vs. user).

#### 2.5 `use_skill` Tool Definition

The `use_skill` tool enables agent-initiated skill invocation.

| Field | Description |
|-------|-------------|
| Name | `use_skill` |
| Parameters | `name` (required, string) — the skill name to invoke |
| Returns | `{:ok, definition}` — the skill's full definition text |
| Errors | `{:error, :not_found}` — no skill with that name exists |
| | `{:error, :no_definition}` — skill exists but has no definition (manifest-only, missing `---` separator) |

The harness handles the tool call by loading the full definition from the Registry and injecting it into context as a system-level instruction. The agent then follows the skill's instructions on the next turn. The tool is always available in the agent's tool list (unlike `cache_read` which is conditional).

Skills with a missing `---` separator (manifest-only) appear in the system prompt listing but return `{:error, :no_definition}` if invoked.

When a skill is invoked (by any means):
1. Look up `review` in the skill registry
2. Load the full definition (everything after the `---` separator)
3. Inject the definition into the conversation as a system-level instruction
4. The agent executes according to the skill's instructions

### 3. Cascade

Three levels, in order of increasing priority:

1. **Built-in** — bundled with the Deft binary (`priv/skills/`, `priv/commands/`)
2. **Global** — user-created, in `~/.deft/skills/` and `~/.deft/commands/`
3. **Project** — project-specific, in `.deft/skills/` and `.deft/commands/`

When names collide, the higher-priority level wins. A project skill named `review` overrides a global skill named `review`, which overrides a built-in skill named `review`.

Skills and commands share a single namespace. If both `review.yaml` (skill) and `review.md` (command) exist at the same cascade level, the skill takes precedence and the command is ignored. Across levels, the normal cascade applies (project > global > built-in).

### 4. Registry

#### 4.1 Discovery

On startup, the registry scans all three levels for skills and commands:

1. Scan `priv/skills/*.yaml` — parse manifest (above `---`), store as built-in
2. Scan `~/.deft/skills/*.yaml` — parse manifest, store as global
3. Scan `.deft/skills/*.yaml` — parse manifest, store as project
4. Repeat for commands: scan `*/commands/*.md` at each level, extract name from filename
5. Apply cascade: for each name, keep only the highest-priority entry

If a skill YAML file fails to parse, the file is skipped with a warning. Deft continues startup. A skill with a missing required field (`name` or `description`) is also skipped with a warning.

Missing directories are treated as empty (no skills/commands at that level). Not an error.

The registry is a map of name → entry, where each entry contains:

```elixir
%Deft.Skills.Entry{
  name: "review",
  type: :skill | :command,
  level: :builtin | :global | :project,
  description: "Perform a comprehensive code review",  # skills only
  path: "/path/to/review.yaml",
  loaded: false  # true once full definition has been read
}
```

#### 4.2 System Prompt Integration

The agent's system prompt includes a listing of available skills and commands so the model knows what's available. Only names and descriptions — not full definitions. This listing gives the agent enough information to suggest or auto-invoke skills when contextually appropriate.

Skills show their manifest description. Commands show their extracted first-line description (see section 1.1).

```
Available skills:
- /review — Perform a comprehensive code review of staged changes
- /deploy-check — Verify deployment readiness

Available commands:
- /commit — Generate a commit message and commit
- /pr — Create a pull request
```

This listing is assembled from the registry at session start.

#### 4.3 Lookup and Loading

When a skill or command is invoked (whether by user slash command or agent auto-invocation):

1. Look up the name in the registry
2. If not found, report "Unknown command: /foo"
3. If found and type is `:command`:
   - Read the markdown file at `path`
   - Inject contents as a user message
4. If found and type is `:skill`:
   - Read the YAML file at `path`
   - Parse out the full definition (content after `---`)
   - Inject the definition into the context
   - Mark `loaded: true` in the registry (avoid re-reading the file on repeated invocations within the same session)

The `load_definition/1` operation must use `Agent.get_and_update/2` to atomically read and cache the definition. Using separate `get` + `update` creates a race where concurrent callers could both read the file.

### 5. Process Architecture

```
Deft.Skills.Registry (Agent — holds the skill/command registry map)
```

- Started by `Deft.Application` on boot
- Runs discovery (section 4.1) during init
- Provides `list/0`, `lookup/1`, `load_definition/1`
- Lightweight — an `Agent` is sufficient since reads far outnumber writes and the data is small

The Registry is application-global but `.deft/skills/` is project-local. On session start, the Registry re-runs discovery for the project level. Built-in and global skills persist across sessions; project skills are re-scanned each session.

### 6. Naming Rules

Skill and command names must match `^[a-z][a-z0-9-]*$`:
- Lowercase letters, digits, hyphens
- Must start with a letter
- No underscores, spaces, or special characters

Files that don't match the naming rules are ignored during discovery (logged as a warning).

### 7. Configuration

No configuration in v0.1. Discovery paths are fixed (built-in, `~/.deft/`, `.deft/`). Cascade order is fixed.

## Notes

### Design decisions

- **Agent can suggest and auto-invoke skills.** The agent sees skill manifests (name + description) in its system prompt, which is sufficient for it to decide when a skill is appropriate — just as it decides when to use any tool. The agent can suggest a skill in prose ("you might want to run /review") or auto-invoke when clearly appropriate based on context. Users can always invoke explicitly via `/name`.
- **Progressive loading.** Loading every skill's full definition at startup would waste context window space. Manifests are tiny (name + description + version). Full definitions can be substantial (multi-step instructions, tool configurations). Loading on demand means the context only pays for skills the user actually invokes.
- **Commands are just files.** No YAML, no frontmatter, no parsing. A markdown file is a prompt. This makes commands trivially easy to create — write a markdown file, drop it in the directory, done. The filename is the command name.
- **YAML with document separator for skills.** The `---` separator cleanly divides machine-readable metadata (manifest) from human-readable instructions (definition). The file is split on the first `\n---\n` and only the first part is parsed as YAML — the remainder is raw text. No need for a separate file per skill.
- **Agent over GenServer for the registry.** The registry is a simple key-value store with rare writes (only on startup and when loading definitions). An `Agent` is the right tool — simpler than a GenServer, no need for `handle_call`/`handle_cast`. `load_definition/1` uses `Agent.get_and_update/2` for atomic read-and-cache to avoid race conditions.
- **Skills take precedence over commands.** Skills and commands share a single namespace. If both exist with the same name at the same cascade level, the skill wins. Skills are richer and more intentional — if someone created both, the skill is the one they want invoked.
- **Three levels match the configuration cascade.** Built-in → global → project mirrors how most tools handle config (defaults → user → project). Users can override built-in behavior without forking, and projects can specialize without affecting global settings.
- **No tool permissions in v0.1.** Skills may want to restrict or expand available tools (e.g., a review skill shouldn't need write access). This is a real need but adds complexity. Deferring until the tool system is more mature.

## References

- [sessions.md](sessions.md) — CLI interface, system prompt assembly
- [harness.md](harness.md) — agent loop, slash command dispatch
- [Claude Code skills](https://docs.anthropic.com/en/docs/claude-code) — inspiration for the skills/commands model
