# Standards

| | |
|--------|----------------------------------------------|
| Version | 0.3 |
| Status | Implemented |
| Last Updated | 2026-03-29 |

## Changelog

### v0.3 (2026-03-29)
- Fixed `test.all` Makefile target: `mix test` → `mix test --include eval --include integration` (bare `mix test` skips eval/integration due to ExUnit.configure exclusions in test_helper.exs)
- Fixed `ci` Makefile target: added `test.eval.check-structure` prerequisite
- Updated dependency list: replaced `breeze` TUI framework with Phoenix web stack (`phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `earmark_parser`, `earmark`) after TUI deprecation in favor of [web-ui](web-ui.md)
- Updated project skeleton: replaced `tui/` with note that web UI lives in `lib/deft_web/` (see [web-ui](web-ui.md))

### v0.2 (2026-03-29)
- Added strong type requirements: `@type t()` on all structs, domain types on all shared values, no raw primitives across boundaries
- Dialyzer moved to pre-commit and added to `make check`
- Added strict Dialyzer flags: `unmatched_returns`, `error_handling`, `underspecs`, `extra_return`, `missing_return`
- Phased removal of `.dialyzer_ignore.exs` — fix all violations first, then delete the file

### v0.1 (2026-03-16)
- Initial spec — Elixir coding standards, Makefile, git hooks, testing strategy, AI evals

## Overview

This spec defines the coding standards, project infrastructure, and quality gates for Deft. It is the first spec to be implemented — it creates the project skeleton, Makefile, git hooks, and test infrastructure that all other specs build on.

Deft is a functional Elixir codebase. It does not shoehorn OOP concepts into Elixir. It follows idiomatic patterns: data flowing through pipes, pattern matching in function heads, explicit ok/error tuples, and processes only where state or concurrency is genuinely needed.

**Scope:**
- Project skeleton and directory structure
- Elixir coding standards and anti-patterns
- Formatting and linting configuration
- Static analysis (Dialyzer)
- Makefile with standard targets
- Git hooks (pre-commit, pre-push) via Lefthook
- Unit testing strategy (critical paths only, not exhaustive)
- AI eval testing strategy (Tribunal)
- CI pipeline definition

**Out of scope:**
- What the code does (see other specs)
- Deployment and release (see [harness.md](harness.md) distribution section)

**Dependencies:**
- None (this is the foundational spec — implemented first)

**Design principles:**
- **Functional, not OOP.** Data flows through functions. Modules are namespaces, not classes. GenServers are for state, not for wrapping business logic.
- **Test critical paths, not every function.** Public context APIs, error paths, business rules, and integration boundaries. Not trivial wrappers.
- **AI evals are first-class.** LLM-powered features (Observer, Reflector, Actor) must have eval tests that verify output quality, not just that they don't crash.
- **Fail fast in CI.** Formatting, linting, compilation warnings, and Dialyzer all fail the build. No warnings-as-warnings culture.

## Specification

### 1. Project Skeleton

```
deft/
├── lib/
│   └── deft/
│       ├── agent/           # Agent loop, gen_statem, context assembly
│       ├── om/              # Observational memory (State, Observer, Reflector)
│       ├── provider/        # LLM provider behaviour and implementations
│       ├── tools/           # Built-in tools (read, write, edit, bash, grep, find, ls)
│       ├── session/         # Session persistence, JSONL store
│       ├── ...              # Other contexts (see individual specs)
│       ├── job/             # Orchestration (Foreman, Lead, Runner, SiteLog, RateLimiter)
│       ├── message.ex       # Canonical message format and content blocks
│       ├── config.ex        # Configuration loading and validation
│       └── application.ex   # OTP application and top-level supervisor
├── test/
│   ├── deft/                # Mirrors lib/ structure
│   ├── eval/                # AI eval tests (tagged @tag :eval)
│   ├── integration/         # Integration tests (tagged @tag :integration)
│   ├── support/             # Test helpers, fixtures, factories
│   └── test_helper.exs
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
├── .formatter.exs
├── .credo.exs
├── lefthook.yml
├── Makefile
├── mix.exs
└── mix.lock
```

### 2. Elixir Coding Standards

#### 2.1 Functional Patterns (Required)

- **Pipe-oriented data flow.** Transform data through pipelines: `data |> validate() |> transform() |> persist()`. Each function is pure where possible.
- **Pattern match in function heads.** Branch on data shape via multiple function clauses, not `if/else` chains inside a single function body.
- **Explicit ok/error tuples.** Functions with fallible outcomes return `{:ok, result}` or `{:error, reason}`. Never return `nil` to signal failure.
- **`with` for chaining fallible operations.** Use `with` when you need to chain 3+ operations that each return `{:ok, _}` or `{:error, _}`. Do NOT use `with` when a simple `case` or pipe would suffice.
- **Assertive code.** Match the shape you expect; let it crash on unexpected input. The supervisor handles the crash. Do not defensively nil-check everything.
- **Structs for domain types.** Use `defstruct` for structured data with known fields. Use maps for ad-hoc or dynamic data.

#### 2.2 Anti-Patterns (Forbidden)

- **GenServer as OOP object.** Do not use GenServer to encapsulate business logic that should be a module with functions. GenServer is for stateful long-running processes, not "service classes."
- **Unnecessary processes.** Do not `spawn` or `Task.async` for performance inside a function unless you have measured that concurrency helps. The overhead of process creation is real.
- **Deep nesting.** No more than 3 levels of `case`/`cond`/`if` nesting. Extract to separate functions with pattern-matched heads.
- **Managerial module names.** Avoid `Manager`, `Handler`, `Processor`, `Factory`, `Strategy` unless they are genuine domain vocabulary. Name modules after what they ARE, not what they DO.
- **Cross-context coupling.** Do not call internal modules of another context directly. Go through the context's public API.
- **Options that change return type.** A function option should not structurally change what is returned.
- **Abusing multi-clause functions.** Do not group unrelated logic into the same function name just because the arity matches.

#### 2.3 Module Organization

- Modules are PascalCase; files are snake_case. `Deft.OM.State` lives in `lib/deft/om/state.ex`.
- Flat over deeply nested. `Deft.Job.Lead` is fine. `Deft.Job.Orchestration.Lead.Management.Steering` is not.
- Context boundaries are respected. `Deft.OM` is a context. `Deft.Agent` is a context. `Deft.Job` is a context. Each exposes a public API; internal modules are not called from outside.
- `@moduledoc` on every public module. `@moduledoc false` on explicitly internal modules.
- `@doc` on every public function. First paragraph is one concise line (used as summary by ExDoc).
- `@spec` on all public functions. Serves as documentation, Dialyzer input, and contract definition.

#### 2.4 Type Discipline

Deft uses strong, domain-specific types. Raw primitives (`String.t()`, `integer()`, `map()`) do not cross module boundaries.

**Required types:**

- **`@type t()` on every struct module.** Every `defstruct` module defines `@type t :: %__MODULE__{}` with all fields typed. No exceptions.
- **Domain types for shared values.** If a value is used as a parameter or return type in more than one module, it gets a named `@type` in the module that owns the concept. Other modules reference it by name. Examples:
  - `Session.id()` not `String.t()` for session identifiers
  - `Message.role()` not `:user | :assistant | :system` repeated everywhere
  - `Tool.result()` not `{:ok, String.t()} | {:error, String.t()}`
  - `Provider.model()` not `String.t()` for model names
- **Callback types on behaviours.** Every `@callback` uses domain types, not primitives. The behaviour module defines the types its callbacks use.

**Forbidden patterns:**

- `@spec foo(String.t()) :: map()` on a public function that takes a session ID and returns a config — use `@spec foo(Session.id()) :: Config.t()`.
- `@type t :: %__MODULE__{data: map()}` with an untyped map field — type the map contents or use a nested struct.
- Duplicating type definitions across modules. One module owns each type. Others reference it.

### 3. Dependencies

```elixir
# mix.exs deps
defp deps do
  [
    # Runtime
    {:req, "~> 0.5"},                    # HTTP client
    {:jason, "~> 1.4"},                  # JSON
    {:yaml_elixir, "~> 2.11"},           # Config parsing
    {:server_sent_events, "~> 0.2"},     # SSE parsing
    {:phoenix, "~> 1.7"},                # Web framework
    {:phoenix_live_view, "~> 0.20"},     # LiveView
    {:phoenix_html, "~> 4.0"},           # HTML helpers
    {:bandit, "~> 1.0"},                 # HTTP server
    {:earmark_parser, "~> 1.4"},         # Markdown parsing
    {:earmark, "~> 1.4"},               # Markdown rendering
    {:burrito, "~> 1.0"},               # Single-binary distribution
    {:dotenvy, "~> 1.1"},               # .env file loading

    # Dev/Test only
    {:phoenix_live_reload, "~> 1.5", only: [:dev]},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:floki, ">= 0.30.0", only: :test},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
    {:stream_data, "~> 1.0", only: [:test]},
    {:mox, "~> 1.1", only: [:test]},
    {:tribunal, "~> 1.3", only: [:test]},
    {:req_llm, "~> 1.2", only: [:test]},
    {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
  ]
end
```

### 4. Formatting

`.formatter.exs`:
```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 98
]
```

Default line length (98). No custom rules. `mix format` is non-negotiable — it runs on every commit via git hooks.

### 5. Linting

`.credo.exs` with `strict: true`. Key enabled checks:
- `Credo.Check.Readability.WithCustomTaggedTuple` — flags misuse of `with`
- `Credo.Check.Warning.MixEnv` — no `Mix.env()` in runtime code
- `Credo.Check.Design.AliasUsage` — enforce aliasing deeply nested modules
- `Credo.Check.Refactor.CyclomaticComplexity` — flag overly complex functions
- `Credo.Check.Refactor.Nesting` — flag deeply nested code

### 6. Static Analysis

Dialyzer via `dialyxir` with strict flags. Runs in pre-commit and CI — no exceptions.

```elixir
# mix.exs
defp dialyzer do
  [
    plt_add_apps: [:mix, :ex_unit],
    plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
    flags: [
      :unmatched_returns,
      :error_handling,
      :underspecs,
      :extra_return,
      :missing_return
    ]
  ]
end
```

**No warning suppression.** There is no `.dialyzer_ignore.exs`. If Dialyzer flags something, fix it — don't suppress it.

### 7. Makefile

```makefile
.PHONY: setup deps compile format format.check lint dialyzer test test.eval test.integration check ci clean

setup: deps
	lefthook install

deps:
	mix deps.get

compile:
	mix compile --warnings-as-errors

format:
	mix format

format.check:
	mix format --check-formatted

lint:
	mix credo --strict

dialyzer:
	mix dialyzer

test:
	mix test --exclude eval --exclude integration

test.eval:
	mix test --only eval

test.integration:
	mix test --only integration

test.all:
	mix test --include eval --include integration

check: compile format.check lint dialyzer test

ci: test.eval.check-structure compile format.check lint dialyzer test.all

clean:
	mix clean
	rm -rf _build deps
```

`make check` is the local quality gate (includes Dialyzer, excludes integration/eval tests).
`make ci` is the full pipeline including all tests.

### 8. Git Hooks

`lefthook.yml`:
```yaml
pre-commit:
  parallel: true
  commands:
    format:
      run: mix format --check-formatted
      glob: "*.{ex,exs}"
    lint:
      run: mix credo --strict
    compile:
      run: mix compile --warnings-as-errors
    dialyzer:
      run: mix dialyzer

pre-push:
  commands:
    test:
      run: mix test --exclude eval
    integration:
      run: mix test --only integration
      tags: integration
```

- **Pre-commit:** formatting, linting, compilation warnings, Dialyzer. Parallel.
- **Pre-push:** unit tests + integration tests. Runs before code reaches remote.
- **AI eval tests** are NOT in hooks — they require API calls, are slow, and are non-deterministic. They run in CI and manually via `make test.eval`.

Lefthook is installed via `make setup` (which runs `lefthook install`).

### 9. Testing Strategy

#### 9.1 What to Test

| Category | Test | Don't test |
|----------|------|-----------|
| **Context APIs** | Every public function on context modules (e.g., `Deft.OM.State.get_context/1`) | Internal helper functions that are only called by tested public functions |
| **Error paths** | All `{:error, _}` return cases on public APIs | Happy-path-only trivial wrappers |
| **Business rules** | Token threshold logic, observation merge semantics, section replacement rules | Phoenix boilerplate, simple delegation |
| **Provider adapters** | SSE parsing, message formatting, event normalization | HTTP client internals (use Mox for the HTTP layer) |
| **Tools** | Edit tool string matching, bash timeout enforcement, output truncation | File.read/write wrappers |
| **Orchestration** | Dependency DAG resolution, partial unblocking logic, merge ordering | Process lifecycle (trust OTP) |

#### 9.2 Mocking Strategy

Use `Mox` exclusively. Mock at system boundaries only:
- `Deft.Provider.Behaviour` — mock LLM responses in agent loop tests
- `Deft.HTTP.Behaviour` — mock HTTP responses in provider tests
- External tool execution — mock `System.cmd` results for tool tests

Do NOT mock internal modules. If you need to mock `Deft.OM.State` to test `Deft.Agent`, your test is wrong — test through the public API or use a real State process.

#### 9.3 Test Tags

```elixir
# Regular unit tests (default, no tag needed)
test "observation merge replaces Current State section" do ...

# Integration tests (hit real filesystem, spawn real processes)
@tag :integration
test "full agent loop with tool execution" do ...

# AI eval tests (hit real LLM APIs, non-deterministic)
@tag :eval
test "Observer extracts file modifications from conversation" do ...
```

- `mix test` — runs unit tests only (excludes `:eval` and `:integration`)
- `mix test --only integration` — integration tests only
- `mix test --only eval` — AI eval tests only
- `mix test` (no exclusions in CI) — runs everything

#### 9.4 Property-Based Testing

Use `StreamData` for:
- Token estimation calibration (for all valid strings, estimate is within 30% of actual)
- Section-aware merge (for all valid observation sections, merge preserves section ordering)
- Message serialization roundtrips (for all valid Messages, encode then decode == original)

#### 9.5 AI Eval Tests (Tribunal)

AI eval tests verify that LLM-powered components produce correct output, not just that they don't crash.

**Observer eval tests:**
```elixir
@tag :eval
test "Observer extracts user-stated facts as high priority" do
  messages = [
    %{role: :user, content: "We use PostgreSQL for our database"},
    %{role: :assistant, content: "Got it, I'll use PostgreSQL."}
  ]

  observations = Deft.OM.Observer.extract(messages, existing_observations: "")

  Tribunal.assert_contains(observations, "PostgreSQL")
  Tribunal.assert_contains(observations, "🔴")
  Tribunal.refute_hallucination(observations, context: messages)
end
```

**Reflector eval tests:**
- Compressed output preserves all 🔴 items from input
- Compressed output is within target token count
- CORRECTION markers survive compression

**What to eval test:**
| Component | Eval criteria |
|-----------|--------------|
| Observer extraction | Captures stated facts, marks correct priority, no hallucinated facts |
| Observer section routing | Facts go to correct sections (file ops → Files & Architecture, preferences → User Preferences) |
| Reflector compression | Preserves high-priority items, maintains section structure, hits target size |
| Actor with observations | References observation content appropriately, doesn't mention OM system |
| Continuation hint | Accurately describes current task and last action |

**Eval test properties:**
- Tagged `@tag :eval` — excluded from fast runs
- Require `ANTHROPIC_API_KEY` in environment
- Are non-deterministic — a single failure is not a bug, but consistent failures indicate a prompt problem
- Use Tribunal's evaluation mode for statistical confidence where needed (e.g., "passes 80% of the time")

### 10. CI Pipeline

The CI pipeline runs on every push:

```
1. mix deps.get
2. mix compile --warnings-as-errors
3. mix format --check-formatted
4. mix credo --strict
5. mix dialyzer (with cached PLT)
6. mix test (unit + integration)
7. mix test --only eval (AI evals, allowed to have some failures — track pass rate)
```

AI eval tests report a pass rate rather than pass/fail. A drop in pass rate triggers investigation, not an automatic build failure (LLM outputs are non-deterministic).

## Notes

### Design decisions

- **Lefthook over elixir_git_hooks.** Lefthook runs hooks in parallel, is language-agnostic (useful if we add Rust NIFs later), and has better ecosystem support. The Elixir-native option is convenient but limited.
- **Credo strict mode from day 1.** Retroactively enabling strict Credo on a large codebase is painful. Starting strict is easy and prevents bad patterns from establishing.
- **Dialyzer in pre-commit.** Static analysis catches type errors before they land. No exceptions.
- **Tribunal for AI evals.** It's the only Elixir-native LLM evaluation framework. It provides both deterministic assertions (`assert_contains`, `assert_json`) and LLM-as-judge assertions (`refute_hallucination`, `assert_faithful`).
- **`make check` vs `make ci`.** `check` includes Dialyzer and unit tests. `ci` adds integration and eval tests.

### Open questions (resolve before Ready)

- **ExCheck integration.** `ex_check` runs format/compile/credo/dialyzer/tests in parallel with streaming output. Could replace the Makefile `check`/`ci` targets. Worth evaluating — may simplify the pipeline.
- **Boundary library.** Saša Jurić's `Boundary` enforces context boundaries at compile time. Worth adding for a project with clear context boundaries (Agent, OM, Job, Provider). Adds a dep but catches cross-context coupling at build time.

## References

- [Elixir Anti-Patterns (official)](https://hexdocs.pm/elixir/what-anti-patterns.html)
- [Towards Maintainable Elixir: Core and Interface (Saša Jurić)](https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43)
- [Elixir Style Guide (christopheradams)](https://github.com/christopheradams/elixir_style_guide)
- [Tribunal — LLM evaluation for Elixir](https://hex.pm/packages/tribunal)
- [Lefthook](https://github.com/evilmartians/lefthook)
- [Credo](https://github.com/rrrene/credo)
- [StreamData](https://github.com/whatyouhide/stream_data)
