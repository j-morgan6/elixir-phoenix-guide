# Elixir Phoenix Guide Plugin - Roadmap

**Last Updated:** 2026-03-13
**Current Version:** 1.3.2
**Status:** Planning for v1.4.0 (Competitive Parity)

This document outlines the evolution of the Elixir Phoenix Guide plugin, tracking completed work and planned improvements.

## Semantic Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR.x.x** (e.g., 2.0.0): Breaking changes or major new features
- **x.MINOR.x** (e.g., 1.1.0): New features, backward-compatible
- **x.x.PATCH** (e.g., 1.0.1): Bug fixes, backward-compatible

**Version Mapping:**
- v1.0.0 = Initial release (7 skills + 10 hooks) ✅
- v1.1.0 = Skill discoverability (forcing language + file patterns) ✅
- v1.2.0 = Consolidation & enforcement (4 skills + RULES sections) ✅
- v1.3.0 = Testing skill (testing-essentials + agent doc refactor) ✅
- v1.3.1 = LiveView rules + template refinements ✅
- v1.3.2 = Testing essentials refinements (setup chaining, timestamps, async, skeletons) ✅
- v1.4.0 = Competitive parity (new hooks, OTP skill, Oban skill, subagent rules injection) ✅
- v2.0.0 = Automation (major new feature set)
- v2.1.0 = Additional skills & polish (minor features after major)
- v2.2.0 = Smart enforcement (context-aware hooks, project detection, migration safety)
- v2.3.0 = Expanded domains (security, deployment, channels, telemetry, JSON API)
- v3.0.0 = Reactive intelligence (error decoder, test analyzer, Credo integration)

See [RELEASE.md](RELEASE.md) for the complete release process.

---

## Executive Summary

The plugin has evolved through three completed releases focused on ensuring skills are consistently used. The core insight driving all decisions:

> **Skills provide value but only when actually invoked. The challenge is adoption, not content.**

**Four-pronged strategy:**
1. **Proactive (Skills)** - Teach patterns upfront before mistakes happen
2. **Preventive (Hooks)** - Enforce patterns in real-time as code is written
3. **Enforced (Forcing Functions)** - Mandatory language makes skills harder to skip
4. **Reactive (Error Guidance)** - When things go wrong, explain why and how to fix (v3.0.0)

---

## ✅ Completed Releases

### v1.0.0 - Initial Release (2026-01-26)

**What shipped:**
- **7 Skills**: elixir-patterns, phoenix-liveview, ecto-database, error-handling, phoenix-uploads, phoenix-static-files, liveview-lifecycle
- **10 Hooks**: 5 blocking (missing-impl, hardcoded-paths, hardcoded-sizes, static-paths-validator, deprecated-components) + 4 warning (nested-if-else, inefficient-enum, string-concatenation, auto-upload-warning)
- **4 Agent Docs**: project-structure, liveview-checklist, ecto-conventions, testing-guide
- **Installation methods**: Marketplace plugin, install script, manual

---

### v1.1.0 - Skill Discoverability (2026-02-09)

**Problem solved:** Advisory "Use when..." language felt optional, leading to low adoption.

**What shipped:**
- All 7 skills updated with "INVOKE BEFORE" forcing language
- File pattern metadata (`file_patterns`, `auto_suggest: true`) added to all skills
- `skill-discovery` meta-skill created with task/file type detection checklist

**Impact:** Systematic skill selection; mandatory language harder to rationalize away.

---

### v1.2.0 - Consolidation & Enforcement (2026-02-12)

**Problem solved:** 8 skills created choice paralysis; advisory language still being skipped.

**What shipped:**
- **Plugin renamed** from `elixir-optimization` → `elixir-phoenix-guide`
- **Skills consolidated** from 8 → 4 (less choice paralysis):
  - `elixir-essentials` (merged elixir-patterns + error-handling)
  - `phoenix-liveview-essentials` (merged phoenix-liveview + liveview-lifecycle)
  - `ecto-essentials` (renamed from ecto-database)
  - `phoenix-uploads` (merged in phoenix-static-files content)
  - Removed `skill-discovery` (no longer needed with fewer skills)
- **RULES sections** added to all 4 skills (7-8 non-negotiable rules, visible in 10 seconds)
- **Skill descriptions strengthened**: "MANDATORY for ALL" replaces "INVOKE BEFORE"
- **CLAUDE.md template** updated with mandatory skill invocation enforcement section
- **Skill reminder hook** added (non-blocking, nudges on .ex/.exs/.heex writes)

**Impact:** Reduced cognitive load, clearer purpose, multiple enforcement touchpoints.

---

### v1.3.0 - Testing Skill (2026-02-22)

**What shipped:**
- **`testing-essentials` skill** with 8 RULES, TDD workflow, and quick pattern reference
- **`testing-guide.md` refactored** as deep reference companion (no duplication with skill)
- **All 4 existing skills** updated with `## Testing` pointers to `testing-essentials`

**Impact:** Plugin now provides complete testing guidance without relying on external plugins.

---

### v1.3.1 - LiveView Rules + Template Refinements (2026-03-04)

**What shipped:**
- **`phoenix-liveview-essentials`** — 2 new rules: check `core_components.ex` before custom components; never query DB directly from LiveViews
- **`CLAUDE.md.template`** — HexDocs MCP note added

**Impact:** Reinforces context boundaries and prevents component duplication.

---

### v1.3.2 - Testing Essentials Refinements (2026-03-08)

**What shipped:**
- **`testing-essentials`** — 4 targeted refinements:
  - Setup Chaining section with `setup [:func1, :func2]` guidance
  - Timestamp Testing section with relative timestamp patterns
  - Refined `async: true` rule with safe/unsafe categorization
  - Improved Context Test Skeleton with result binding and error assertions

**Deferred to future release:**
- Module size thresholds for `elixir-essentials`
- Security audit commands (`mix deps.audit`, `mix hex.audit`, `mix sobelow`)

**Impact:** Prevents flaky timestamp tests; clearer async guidance reduces intermittent CI failures.

---

## Upcoming Releases

---

## Version 1.4.0 - Competitive Parity (Hooks, OTP Skill, Subagent Enforcement)

**Priority:** 🔴 **HIGH**
**Effort:** Medium (~20 hours)
**Impact:** High
**Target:** March 2026

**Motivation:** Competitive analysis of [oliver-kriska/claude-elixir-phoenix](https://github.com/oliver-kriska/claude-elixir-phoenix) (v2.3.1) identified gaps in hook coverage, domain breadth, and subagent enforcement. This release closes the most visible gaps while maintaining our lean, enforcement-first philosophy.

### 1.4.1 New Hooks (Quick Wins)

#### dangerous-operations-blocker (Blocking — exit 2)

**Purpose:** Prevent destructive operations that cause irreversible damage

**Operations to Block:**
- `mix ecto.reset` — destroys and recreates database
- `git push --force` / `git push -f` — overwrites remote history
- `MIX_ENV=prod` in Bash commands — accidental production operations
- `Repo.delete_all` without a where clause — full table wipe

**Implementation:** PreToolUse hook on Bash tool, pattern match on command strings.

#### debug-statement-detector (Warning — exit 1)

**Purpose:** Catch debug statements left in code before they reach production

**Statements to Detect:**
- `IO.inspect` (outside test files)
- `dbg()` calls
- `IO.puts` used for debugging (outside scripts)
- `Logger.debug` with hardcoded strings (suggest structured logging)

**Implementation:** PostToolUse hook on Write/Edit tools, grep-based check on file content.

#### security-audit-reminder (Reminder — exit 0)

**Purpose:** Nudge security scanning when dependencies change

**Trigger:** When `mix.exs` is edited (deps section modified)

**Reminder Text:**
```
💡 Dependencies changed. Consider running:
   mix deps.audit    — check for known vulnerabilities
   mix hex.audit     — verify package checksums
   mix sobelow       — static security analysis
```

**Implementation:** PostToolUse hook on Write/Edit for `mix.exs`.

### 1.4.2 New Skill: otp-essentials

**Purpose:** Guide OTP patterns — GenServer, Supervisor, Task, Agent

**File Pattern Trigger:** `**/*.ex` (when GenServer/Supervisor/Task usage detected)

**RULES (Non-Negotiable):**
1. Always use `@impl true` before GenServer callbacks
2. Keep `init/1` fast — no blocking calls, use `handle_continue` for expensive setup
3. Use `GenServer.call` for request/response, `GenServer.cast` for fire-and-forget
4. Always define a public API module wrapping GenServer calls — never call GenServer directly from other modules
5. Supervisors must define a `child_spec/1` or use `use GenServer`/`use Agent` which provides one
6. Use `Task.async`/`Task.await` for concurrent work with bounded timeouts — never `Task.async` without `Task.await`
7. Name processes via Registry, not atoms — atom table is finite and never garbage collected

**Should Cover:**
- GenServer lifecycle (init, handle_call, handle_cast, handle_info, terminate)
- Supervisor strategies (one_for_one, one_for_all, rest_for_one)
- Dynamic supervisors for runtime child processes
- Task patterns (async/await, async_stream, supervised tasks)
- Agent for simple state (when GenServer is overkill)
- Process linking vs monitoring
- ETS for shared read-heavy state
- Common anti-patterns (bottleneck GenServer, god process, unmonitored processes)

**Estimated Effort:** 6 hours

### 1.4.3 New Skill: oban-essentials

**Purpose:** Guide Oban background job patterns

**File Pattern Trigger:** `**/workers/**/*.ex`, `**/*_worker.ex`

**RULES (Non-Negotiable):**
1. Always `use Oban.Worker` with explicit `queue` and `max_attempts` options
2. Return `{:ok, result}` for success, `{:error, reason}` for retryable failures, `{:cancel, reason}` for permanent failures
3. Make workers idempotent — the same job may run more than once
4. Use `unique` option to prevent duplicate jobs — specify `period`, `fields`, and `keys`
5. Test workers with `Oban.Testing` — use `assert_enqueued` and `perform_job`, never call `perform/1` directly
6. Never put large data in job args — store IDs and fetch fresh data in the worker
7. Use `Oban.insert/1` (not `Oban.insert!/1`) and handle the error tuple

**Should Cover:**
- Worker definition and configuration
- Queue configuration in `config.exs`
- Job scheduling (schedule_in, cron)
- Testing with `Oban.Testing` (inline mode, assert_enqueued, perform_job)
- Error handling and retry strategies
- Unique jobs and deduplication
- Oban Pro detection (if using `Oban.Pro.Worker`, adjust advice)
- Pruning and job lifecycle

**Estimated Effort:** 5 hours

### 1.4.4 SubagentStart Hook: Rules Injection

**Purpose:** Ensure plugin rules follow into subagents spawned by Claude

**Problem:** When Claude spawns subagents (via the Agent tool), those subagents don't inherit skill rules. Code written by subagents bypasses all enforcement.

**Implementation:** SubagentStart hook that injects a condensed version of all RULES into every spawned subagent's context.

**Injected Content:**
```
## Elixir Phoenix Guide — Rules for Subagents

You are working in an Elixir/Phoenix project. Follow these rules strictly:

### Elixir Rules
[condensed rules from elixir-essentials]

### LiveView Rules
[condensed rules from phoenix-liveview-essentials]

### Ecto Rules
[condensed rules from ecto-essentials]

### Testing Rules
[condensed rules from testing-essentials]

### OTP Rules
[condensed rules from otp-essentials]
```

**Estimated Effort:** 3 hours

### Estimated Effort Breakdown

| Task | Effort |
|------|--------|
| dangerous-operations-blocker hook | 1 hour |
| debug-statement-detector hook | 1 hour |
| security-audit-reminder hook | 1 hour |
| otp-essentials skill | 6 hours |
| oban-essentials skill | 5 hours |
| SubagentStart rules injection hook | 3 hours |
| Testing and documentation | 3 hours |
| **Total** | **~20 hours** |

---

## Future Considerations (Inspired by Competitive Analysis)

These ideas from the competitive analysis are valuable but lower priority. They don't fit the v1.4.0 scope but should be revisited:

- **security-essentials skill** — atom exhaustion, SSRF, rate limiting, CSP headers, input sanitization (beyond auth patterns planned for v2.1.0)
- **deployment-essentials skill** — Docker multi-stage builds, Fly.io, runtime.exs gotchas, health endpoints, release commands for migrations
- **N+1 query detection command** — targeted analysis tool (simpler than multi-agent approach: warn when `Repo.all` inside `Enum.map`)
- **Phoenix 1.8 Scope patterns** — `current_scope` vs `current_user`, scoped context functions
- **Intent detection** — auto-routing user requests to the right skill (lower priority since we have only 5-7 skills vs 38)

---

## Version 2.2.0 - Smart Enforcement (Context-Aware Hooks)

**Priority:** 🟠 **MEDIUM**
**Effort:** Medium (~24 hours)
**Impact:** High
**Target:** After v2.1.0

Current hooks are static pattern matchers — they grep for strings regardless of context. This release makes hooks project-aware and adds PostToolUse validation for catching issues after code is written.

### 2.2.1 Project Detection System

**Purpose:** Read `mix.exs` to detect project characteristics that change how hooks behave. Only detect things that actually alter enforcement — no detection for detection's sake.

**Detection Targets (must change hook behavior):**
- **Phoenix version** — 1.7 (no Scope) vs 1.8+ (Scope struct, scoped contexts) → adjusts auth-related hooks and skill advice
- **LiveView presence** — skip LiveView hooks/skills entirely if project is API-only
- **Ecto adapter** — Postgres vs SQLite → some index/constraint advice differs (e.g., partial indexes not supported in SQLite)
- **Oban presence** — enable/disable oban-essentials skill trigger

**Implementation:** SessionStart hook that parses `mix.exs` and writes a `.elixir-phoenix-guide-project.json` cache file. Other hooks read this file to conditionally apply rules.

**Example:**
```json
{
  "phoenix_version": "1.8.0",
  "has_liveview": true,
  "has_oban": true,
  "ecto_adapter": "postgres"
}
```

**Principle:** Every detection target must map to a concrete hook behavior change. If it doesn't change enforcement, don't detect it.

**Estimated Effort:** 4 hours

### 2.2.2 Migration Safety Hook (Blocking — exit 2)

**Purpose:** Catch unsafe migration operations before they reach production.

**Operations to Block/Warn:**
- Removing a column without a safety period (data loss)
- Changing column types without a default (breaks running code during deploy)
- Adding a NOT NULL column without a default (locks table on large datasets)
- Missing index on foreign key columns
- `execute("DROP TABLE ...")` without confirmation

**Implementation:** PreToolUse hook on Write/Edit for files matching `**/migrations/**/*.exs`.

**Example Output:**
```
🚫 Unsafe Migration Detected
   Removing column :avatar_url from :users without safety period.

   💡 Safer approach: Add a separate migration to:
   1. Stop reading the column in code
   2. Deploy
   3. Remove the column in a follow-up migration
```

**Estimated Effort:** 4 hours

### 2.2.3 PostToolUse Validation Hooks

**Purpose:** Validate code *after* it's been written, catching issues that PreToolUse pattern matching can't.

**Hooks to Add:**
- **missing-preload** — After writing a query, warn if an association is accessed without being preloaded
- **missing-error-clause** — After writing a `with` statement, warn if there's no `else` clause handling errors
- **raw-sql-warning** — After writing `Ecto.Adapters.SQL.query`, warn about SQL injection risk and suggest parameterized queries
- **context-boundary-violation** — After writing a LiveView, warn if `Repo` is called directly instead of through a context

**Implementation:** PostToolUse hooks on Write/Edit, using grep on the written file content.

**Estimated Effort:** 8 hours

### 2.2.4 Auto-Fix Suggestions

**Purpose:** Upgrade existing warning hooks to include copy-pasteable fix suggestions, not just warnings.

**Example — nested-if-else hook upgrade:**
```
⚠️  Nested if/else detected at line 45.

   Current:
     if condition_a do
       if condition_b do
         ...

   💡 Suggested fix:
     case {condition_a, condition_b} do
       {true, true} -> ...
       {true, false} -> ...
       _ -> ...
     end
```

**Estimated Effort:** 6 hours

---

## Version 2.3.0 - Expanded Domain Coverage

**Priority:** 🟡 **MEDIUM-LOW**
**Effort:** Medium (~28 hours)
**Impact:** Medium
**Target:** After v2.2.0

New skills covering Phoenix development domains not yet addressed.

### 2.3.1 Security Hook Set + Skill

**Purpose:** Enforce security patterns through hooks, not just teach them. Other plugins document security; ours blocks insecure code from being written.

**Approach:** Security gets BOTH a skill (for context/education) AND dedicated blocking/warning hooks (for enforcement). The hooks are the differentiator — the skill exists to explain *why* the hooks fire.

**New Blocking Hooks (exit 2):**
- **atom-from-user-input** — Block `String.to_atom/1` and `String.to_existing_atom/1` on params/user input
- **unparameterized-sql** — Block string interpolation inside `Ecto.Adapters.SQL.query` and `fragment`
- **unsafe-redirect** — Block `redirect(to: params["url"])` without validation (open redirect)

**New Warning Hooks (exit 1):**
- **raw-html-warning** — Warn on `raw/1` and `Phoenix.HTML.raw/1` usage in templates (XSS risk)
- **sensitive-logging** — Warn when `Logger` calls include variables named `password`, `token`, `secret`, `key`
- **timing-unsafe-compare** — Warn on `==` comparison with tokens/secrets, suggest `Plug.Crypto.secure_compare/2`

**Companion Skill (security-essentials):**
- Lightweight — explains what each hook catches and why it matters
- Points to OWASP references for deeper reading
- Covers dependency auditing commands (`mix deps.audit`, `mix hex.audit`, `mix sobelow`)

**Estimated Effort:** 8 hours (6 for hooks, 2 for skill)

### 2.3.2 deployment-gotchas Skill

**Purpose:** Not a deployment guide — a list of the 7 things that break every first Phoenix deploy. Opinionated, not encyclopedic.

**Philosophy:** Other plugins document *how* to deploy. This skill documents *what will go wrong* and how to prevent it. Every rule maps to a real production incident pattern.

**RULES (Draft):**
1. Use `runtime.exs` for secrets and URLs — `config.exs`/`prod.exs` are compiled into the release and cannot read env vars at boot
2. Run migrations via release commands (`bin/migrate`) — `mix` is not available in production releases
3. Set `PHX_HOST` and `PHX_SERVER=true` — without these, URL generation breaks and the server won't start
4. Run `mix assets.deploy` before building the release — forgetting this means no CSS/JS in production
5. Never hardcode secrets — use `System.get_env!/1` in `runtime.exs` (the `!` crashes on boot if missing, which is what you want)
6. Add a `/health` endpoint that queries the database — load balancers need it, and a 200-only check hides DB connection failures
7. Use `config :logger, level: :info` in production — `:debug` logs query parameters including user data

**Not Covered (intentionally):** Docker templates, Fly.io setup, Kubernetes manifests. Those are deployment-platform docs, not Phoenix-specific gotchas. Link to official docs instead.

**Estimated Effort:** 3 hours

### 2.3.3 phoenix-channels-essentials Skill

**Purpose:** Guide Phoenix Channels for non-LiveView real-time features (mobile clients, external APIs, inter-service communication).

**RULES (Draft):**
1. Always authenticate in `connect/3` — channels bypass Plug pipeline
2. Authorize in `join/3` — verify the user can access the requested topic
3. Use `handle_in` for client-to-server, `push` for server-to-client, `broadcast` for server-to-all
4. Keep channel modules thin — delegate business logic to contexts
5. Use Presence for tracking connected users — don't roll your own
6. Return `{:reply, :ok, socket}` or `{:reply, {:error, reason}, socket}` from `handle_in` — don't silently drop messages

**Should Cover:**
- Socket authentication (token-based for mobile/SPA clients)
- Topic structure and naming conventions
- Channel lifecycle (join, leave, handle_in, handle_info)
- Presence tracking
- Testing channels with `ChannelTest`
- When to use Channels vs LiveView vs PubSub

**Estimated Effort:** 5 hours

### 2.3.4 telemetry-essentials Skill

**Purpose:** Guide observability patterns with `:telemetry`, `Logger`, and Ecto telemetry.

**RULES (Draft):**
1. Use structured logging (`Logger.info("action", key: value)`) — never string interpolation in log messages
2. Attach telemetry handlers in `Application.start/2` — not in modules that may restart
3. Use `Ecto.Repo` telemetry events for query monitoring — don't wrap every query manually
4. Use `Phoenix.LiveDashboard` in dev/staging — it's free observability
5. Tag telemetry events with metadata (user_id, request_id) for correlation
6. Never log at `:debug` level in production — it includes query parameters and PII

**Should Cover:**
- `:telemetry` basics (execute, attach, span)
- Ecto telemetry events (query timing, queue time)
- Phoenix telemetry events (request lifecycle)
- LiveDashboard setup and custom pages
- Structured logging with Logger metadata
- Custom metrics for business events
- Integration with external tools (Prometheus, Datadog)

**Estimated Effort:** 5 hours

### 2.3.5 phoenix-json-api Skill

**Purpose:** Guide JSON API development with Phoenix (not LiveView).

**RULES (Draft):**
1. Use `Phoenix.Controller` with `:api` pipeline — don't mix HTML and JSON pipelines
2. Render errors as structured JSON (`{:error, changeset}` → `{"errors": {...}}`)
3. Use Scrivener or offset/limit for pagination — never return unbounded collections
4. Version APIs via URL prefix (`/api/v1/`) — not headers
5. Use `FallbackController` for consistent error handling across controllers
6. Authenticate API requests via Bearer tokens in `Authorization` header — not cookies
7. Always set `Content-Type: application/json` — use `json/2` helper, not `render`

**Should Cover:**
- API pipeline setup in `router.ex`
- Controller patterns for CRUD
- JSON rendering (views vs `json/2`)
- Error handling with FallbackController
- Token-based authentication (Guardian, custom)
- Pagination patterns
- Testing API endpoints with `ConnCase`
- API versioning strategies

**Estimated Effort:** 5 hours

### Estimated Effort Breakdown

| Task | Effort |
|------|--------|
| Security hook set (6 hooks) + companion skill | 8 hours |
| deployment-gotchas | 3 hours |
| phoenix-channels-essentials | 5 hours |
| telemetry-essentials | 5 hours |
| phoenix-json-api | 5 hours |
| Documentation | 2 hours |
| **Total** | **~28 hours** |

---

## Version 3.0.0 - Reactive Intelligence (Error-Driven Guidance)

**Priority:** 🟡 **LOW**
**Effort:** High (~40 hours)
**Impact:** Very High
**Target:** Long-term vision

**Philosophy shift:** Instead of only teaching patterns *before* mistakes happen, react to mistakes *as they happen* with targeted guidance. This is the plugin's fourth enforcement prong:

1. **Proactive (Skills)** — Teach patterns upfront
2. **Preventive (Hooks)** — Block/warn during writes
3. **Enforced (Forcing Functions)** — Ensure skills are invoked
4. **Reactive (Error Guidance)** — When things go wrong, explain why and how to fix

### 3.1 Elixir Error Decoder (PostToolUseFailure Hook)

**Purpose:** When `mix compile`, `mix test`, or `mix ecto.migrate` fails, parse the error output and provide Phoenix-specific guidance.

**Error Mappings:**
| Error Pattern | Guidance |
|---------------|----------|
| `(KeyError) key :foo not found in assigns` | LiveView assign not initialized in mount — list all assigns and check mount/3 |
| `(Ecto.NoResultsError)` | Use `Repo.get` (returns nil) instead of `Repo.get!` (raises) unless you want a 404 |
| `(Ecto.ConstraintError) unique_constraint` | Add `unique_constraint/3` to changeset — database caught it but user sees a crash |
| `(UndefinedFunctionError) function X.changeset/2` | Schema is missing changeset function — check module name and import |
| `(Postgrex.Error) relation "x" does not exist` | Migration not run — `mix ecto.migrate` |
| `(Phoenix.Router.NoRouteError)` | Route not defined — check `mix phx.routes` output |
| `** (CompileError) ... is undefined` | Module or function doesn't exist — check spelling, imports, and aliases |
| `(Ecto.CastError) value ... for field` | Wrong type in changeset cast — check schema field type vs input |

**Implementation:** PostToolUseFailure hook on Bash tool, pattern matching on stderr output.

**Estimated Effort:** 12 hours

### 3.2 Test Failure Analyzer

**Purpose:** When tests fail, provide targeted guidance beyond the raw error output.

**Analysis Targets:**
- **Flaky tests** — detect time-dependent assertions, async race conditions
- **Setup failures** — missing fixtures, wrong case module, sandbox not checked out
- **Assertion mismatches** — suggest correct assertion pattern (e.g., `assert_redirect` instead of checking `conn.status`)
- **LiveView test failures** — common patterns (element not found → check render, event not handled → check handle_event)

**Estimated Effort:** 10 hours

### 3.3 Compilation Warning Enforcer

**Purpose:** PostToolUse hook that parses `mix compile` warnings and surfaces them as actionable items.

**Warnings to Surface:**
- Unused variables → suggest prefixing with `_`
- Unused aliases/imports → suggest removal
- Deprecated function calls → suggest replacement
- Missing `@impl true` on callbacks (complements existing hook with compiler-level detection)
- Unreachable clauses → pattern matching order issue

**Estimated Effort:** 6 hours

### 3.4 Credo Integration Hook

**Purpose:** Run Credo on edited files and surface issues inline.

**Trigger:** PostToolUse on Write/Edit for `.ex`/`.exs` files

**Behavior:**
- Run `mix credo <file> --strict --format json` on the edited file
- Parse JSON output and surface top 3 issues as warnings
- Skip if Credo is not in deps (graceful degradation)

**Example Output:**
```
💡 Credo: lib/app_web/live/post_live.ex
   ├── [refactor] Module has 320 lines (max 200) — consider splitting
   ├── [readability] Pipe chain should start with a raw value, not a function call
   └── [design] Function has cyclomatic complexity of 12 (max 9)
```

**Estimated Effort:** 4 hours

### 3.5 Mix Task Recipes Agent Doc

**Purpose:** Reference document for common custom mix tasks.

**Recipes:**
- Data migration task (backfill a new column)
- Seed data task (idempotent seeds)
- Maintenance task (cleanup old records, expire tokens)
- Report generation task (aggregate and output)
- One-time fix task (with safety checks and dry-run mode)

**Estimated Effort:** 3 hours

### 3.6 Ecto Query Performance Agent Doc

**Purpose:** Reference document for optimizing Ecto queries.

**Should Cover:**
- Reading EXPLAIN ANALYZE output
- Index strategies (B-tree, GIN, partial, covering)
- N+1 detection patterns
- Connection pool tuning (queue_target, queue_interval)
- Ecto query plan logging in dev
- Common slow query patterns and fixes
- When to use raw SQL vs Ecto.Query

**Estimated Effort:** 5 hours

---

## Version 2.0.0 - Automation (Code Quality Detection)

**Priority:** 🔴 **HIGH**
**Effort:** High (~60 hours)
**Impact:** Very High
**Target:** Month 2

**Note:** Major version bump due to significant new automation features that go beyond skill/hook guidance.

Based on analysis showing ~500+ lines of duplicated code eliminated through systematic refactoring in real Phoenix projects.

### 2.1 Code Duplication Detection System

**Purpose:** Automatically detect duplicated functions across modules

**Detection Rules:**
- **Threshold:** 2+ files share >70% identical function implementations
- **Confidence:** High when 3+ files share the same pattern
- **Action:** Suggest creating shared module with concrete refactoring example

**Example Detection:**
```elixir
# Pattern: Same private helper in 3+ LiveView modules
defp format_time(%Decimal{} = seconds) do
  seconds |> Decimal.to_float() |> format_time()
end

defp format_time(seconds) when is_number(seconds) do
  # ... 20 lines of formatting logic ...
end

# Detection Output:
# ⚠️  Duplication Detected
# Function `format_time/1` found in 3 modules:
#   - lib/app_web/live/cycle_time.ex:45
#   - lib/app_web/live/lead_time.ex:52
#   - lib/app_web/live/wait_time.ex:48
#
# 💡 Suggestion: Extract to shared module
# Create: lib/app_web/live/helpers.ex
# Impact: -370 lines of duplicated code
```

**Implementation Approach:**
1. AST-based similarity analysis using Elixir parser
2. Track function signatures and bodies
3. Generate similarity score (0-100%)
4. Flag when threshold exceeded

### 2.2 Template Duplication Detection

**Purpose:** Detect duplicated HEEx markup across templates

**Detection Rules:**
- **Threshold:** 2+ templates share >50 consecutive identical lines
- **Confidence:** Very high when class names and structure match exactly
- **Action:** Suggest extracting to function component

**Example Detection:**
```
# ⚠️  Template Duplication Detected
# 86 identical lines in:
#   - lib/app_web/live/cycle_time.html.heex:12-98
#   - lib/app_web/live/lead_time.html.heex:15-101
#
# 💡 Suggestion: Extract to function component
# Create: lib/app_web/live/components.ex
# Component: metric_filters/1
# Impact: -172 lines, improved maintainability
```

### 2.3 ABC Complexity Analyzer

**Purpose:** Flag functions exceeding complexity thresholds

**Detection Rules:**
- **Threshold:** Function ABC complexity > 30 (configurable)
- **Action:** Suggest breaking into smaller helper functions
- **Integration:** Based on Credo complexity analysis

**Example Detection:**
```
# ⚠️  High Complexity Detected
# Function `calculate_trend_line/1` has ABC complexity of 41 (threshold: 30)
# Location: lib/app_web/live/helpers.ex:45
#
# 💡 Suggestion: Break into smaller functions
# Extract: calculate_regression_sums/1, calculate_slope/5, calculate_intercept/4
# Target: <20 complexity per function
```

### 2.4 Unused Function Detection

**Purpose:** Detect unused private functions after refactoring

**Detection Rules:**
- **Threshold:** Private functions never called
- **Action:** Suggest removal
- **Integration:** Based on compiler warnings

### Invocation Triggers

1. **On File Save** - Detect duplication in the file being edited
2. **On Module Creation** - Warn if creating LiveView similar to existing ones
3. **On Template Edit** - Detect markup duplication
4. **On CI/CD** - Run as quality check before merge
5. **On Demand** - Via `mix elixir_optimization.analyze`

**Estimated Effort:** 40-60 hours
**Expected Impact:** Prevents 500+ lines of duplicated code per project

---

## Version 2.1.0 - Additional Skills & Polish

**Priority:** 🟠 **MEDIUM**
**Effort:** Medium (~32 hours)
**Impact:** Medium-High
**Target:** Month 3

This release combines the battle-tested skills originally planned for v1.2.0 (deferred during consolidation) with additional PubSub/authorization patterns and quality hooks.

### 2.1 Battle-Tested Skills (Deferred from v1.2.0)

These cover patterns learned through 30-90 minutes of painful debugging in real Phoenix development.

#### phoenix-liveview-auth

**Purpose:** Guide LiveView authentication implementation
**Pain Point:** LiveViews don't automatically inherit auth assigns from controller plugs

**Should Cover:**
- `on_mount` callback patterns for authentication
- `current_scope` vs `current_user` patterns
- Import conflicts between `Phoenix.Controller` and `Phoenix.LiveView` (redirect/2, put_flash/3)
- Session token extraction in LiveViews
- `assign_new/3` for conditional assigns
- Testing LiveView redirects in `mount/3`

**Key Patterns:**
```elixir
# on_mount authentication
def on_mount(:require_authenticated_user, _params, session, socket) do
  socket = mount_current_scope(socket, session)
  if socket.assigns.current_scope && socket.assigns.current_scope.user do
    {:cont, socket}
  else
    {:halt, socket |> LiveView.put_flash(:error, "Login required") |> LiveView.redirect(to: ~p"/login")}
  end
end

# Resolving import conflicts
import Phoenix.Controller, except: [redirect: 2, put_flash: 3]

# Safe template access
<%= if assigns[:current_scope] && @current_scope.user do %>
```

#### ecto-changeset-patterns

**Purpose:** Different changeset types and composition patterns
**Pain Point:** `cast_assoc` foreign key requirements, conditional validation, changeset organization

**Should Cover:**
- Separate changesets for different operations (registration, update, profile, password)
- Changeset composition with pipe operator
- Conditional validation with opts pattern
- `unsafe_validate_unique` + `unique_constraint` combo
- **CRITICAL:** `cast_assoc` and required fields (don't require foreign keys!)
- `update_change/3` for field transformations

**Key Patterns:**
```elixir
# Separate changesets for different contexts
def registration_changeset(user, attrs, opts \\ [])
def email_changeset(user, attrs)
def password_changeset(user, attrs)
def profile_changeset(user, attrs)

# CRITICAL: cast_assoc pattern - DON'T require foreign keys
def changeset(ingredient, attrs) do
  ingredient
  |> cast(attrs, [:name, :quantity, :unit, :order, :post_id])
  |> validate_required([:name])  # NOT :post_id - set automatically!
end
```

#### phoenix-auth-customization

**Purpose:** Extending `phx.gen.auth` with custom fields
**Pain Point:** Migration patterns, fixture updates, password vs magic link conflicts

**Should Cover:**
- Running `phx.gen.auth` with correct arguments
- Creating separate migrations for custom fields (never modify generated migrations)
- Updating `User.registration_changeset` for new fields
- Username validation patterns (length, format, uniqueness)
- Test fixture updates when adding required fields
- Confirming users in fixtures for password-based auth

**Key Patterns:**
```elixir
# Fixture for password-based auth
def user_fixture(attrs \\ %{}) do
  {:ok, user} = attrs |> Enum.into(%{
    email: unique_user_email(),
    username: unique_user_username(),
    password: "hello world!"
  }) |> Accounts.register_user()

  # Confirm user for password-based auth
  {:ok, user} =
    user
    |> Ecto.Changeset.change(%{confirmed_at: DateTime.utc_now(:second)})
    |> Repo.update()

  user
end
```

### 2.2 Additional Skills

#### phoenix-pubsub-patterns

**Purpose:** Guide for real-time updates with PubSub

**Should Cover:**
- `connected?/1` guard usage (prevent duplicate subscriptions)
- Topic naming conventions (`"resource:action"`)
- Broadcasting from contexts
- Handling real-time updates in LiveView
- Testing PubSub interactions

**Key Patterns:**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "posts:new")
  end
  {:ok, assign(socket, :posts, list_posts())}
end

def handle_info({:new_post, post}, socket) do
  {:noreply, update(socket, :posts, &[post | &1])}
end
```

#### phoenix-authorization-patterns

**Purpose:** Implementing authorization in Phoenix applications

**Should Cover:**
- Owner-only actions pattern
- Server-side authorization in event handlers (always verify)
- Policy modules pattern
- Role-based access control
- `data-confirm` for destructive actions
- Testing authorization

**Key Patterns:**
```elixir
# Server-side authorization (CRITICAL - UI check alone is not security)
def handle_event("delete", _params, socket) do
  if socket.assigns.current_scope.user.id == socket.assigns.post.user_id do
    # Allow deletion
  else
    {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

#### ecto-nested-associations

**Purpose:** Creating schemas with nested associations

**Should Cover:**
- Order of operations for related schemas
- Using `cast_assoc` and `cast_embed`
- Handling one-to-many relationships
- Transaction patterns with `Ecto.Multi`
- Migration patterns for related tables
- Foreign key cascade rules (`on_delete: :delete_all` vs `:nothing`)

**Key Patterns:**
```elixir
# Parent reference - don't cascade
add :user_id, references(:users, on_delete: :nothing)

# Child reference - cascade delete
add :post_id, references(:posts, on_delete: :delete_all)

# Ecto.Multi for nested creation
Multi.new()
|> Multi.insert(:parent, changeset)
|> Multi.insert_all(:children, Child, fn %{parent: parent} ->
  build_children(parent, attrs)
end)
|> Repo.transaction()
```

### 2.3 Quality Hooks

**Pre-Migration Hook**
```bash
#!/bin/bash
# Check for missing indexes on foreign keys
# Validate on_delete strategies
# Warn about missing timestamps
```

**Pre-Commit Hook**
```bash
#!/bin/bash
# Run mix format --check-formatted
# Run mix compile --warnings-as-errors
# Run mix credo --strict
```

**Estimated Effort:** 24-32 hours
**Expected Impact:** Saves 30-90 min debugging per common pattern

---

## Lower Priority Items

### phoenix-project-init

**Purpose:** Guide initial Phoenix project setup
**Why Lower Priority:** Only needed once per project

**Should Cover:**
- `phoenix.new` with correct flags (`--live`, `--database postgres`)
- `.tool-versions` setup for asdf
- `mix.exs` initial dependencies
- Database configuration

### Pattern Templates Library

**Purpose:** Reusable code snippets for common patterns

**Templates to Include:**
- Soft delete pattern
- Filename generation for uploads
- Tag normalization
- Username validation
- Grid layout for photo galleries
- Placeholder avatars with initials

---

## Implementation Roadmap

### Phase 0: Competitive Parity (v1.4.0)
**Timeline:** 1-2 weeks
**Focus:** Close gaps identified in competitive analysis
**Type:** Minor release

| Task | Effort |
|------|--------|
| 3 new hooks (dangerous ops, debug detection, security reminder) | 3 hours |
| otp-essentials skill | 6 hours |
| oban-essentials skill | 5 hours |
| SubagentStart rules injection hook | 3 hours |
| Testing and documentation | 3 hours |

**Success Metric:** 7 skills + 14 hooks + subagent enforcement; parity on OTP/Oban coverage

### Phase 1: Automation (v2.0.0)
**Timeline:** 4-6 weeks
**Focus:** Build detection system
**Type:** Major release

| Task | Effort |
|------|--------|
| Code duplication detection | 20 hours |
| Template duplication detection | 15 hours |
| ABC complexity analyzer | 10 hours |
| Integration and testing | 15 hours |

**Success Metric:** Detect 80%+ of duplication cases automatically

### Phase 2: Additional Skills & Hooks (v2.1.0)
**Timeline:** 2-3 weeks after v2.0.0
**Focus:** Battle-tested patterns + more skills
**Type:** Minor release

| Task | Effort |
|------|--------|
| phoenix-liveview-auth | 3 hours |
| ecto-changeset-patterns | 3 hours |
| phoenix-auth-customization | 3 hours |
| phoenix-pubsub-patterns | 3 hours |
| phoenix-authorization-patterns | 3 hours |
| ecto-nested-associations | 3 hours |
| Quality hooks (pre-migration, pre-commit) | 8 hours |
| Documentation | 4 hours |

**Success Metric:** Comprehensive coverage of Phoenix development patterns

### Phase 3: Smart Enforcement (v2.2.0)
**Timeline:** 2-3 weeks after v2.1.0
**Focus:** Context-aware hooks and project detection
**Type:** Minor release

| Task | Effort |
|------|--------|
| Project detection system | 4 hours |
| Migration safety hook | 4 hours |
| PostToolUse validation hooks (4) | 8 hours |
| Auto-fix suggestions for existing hooks | 6 hours |

**Success Metric:** Hooks adapt to project stack; unsafe migrations blocked; post-write validation catches context violations

### Phase 4: Expanded Domain Coverage (v2.3.0)
**Timeline:** 3-4 weeks after v2.2.0
**Focus:** New domain skills + security enforcement hooks
**Type:** Minor release

| Task | Effort |
|------|--------|
| Security hook set (6 hooks) + companion skill | 8 hours |
| deployment-gotchas | 3 hours |
| phoenix-channels-essentials | 5 hours |
| telemetry-essentials | 5 hours |
| phoenix-json-api | 5 hours |
| Documentation | 2 hours |

**Success Metric:** 6 new security enforcement hooks; 12+ skills covering all major Phoenix domains

### Phase 5: Reactive Intelligence (v3.0.0)
**Timeline:** 4-6 weeks after v2.3.0
**Focus:** Error-driven guidance and tooling integration
**Type:** Major release

| Task | Effort |
|------|--------|
| Elixir error decoder (PostToolUseFailure) | 12 hours |
| Test failure analyzer | 10 hours |
| Compilation warning enforcer | 6 hours |
| Credo integration hook | 4 hours |
| Mix task recipes agent doc | 3 hours |
| Ecto query performance agent doc | 5 hours |

**Success Metric:** Common errors produce actionable guidance; Credo issues surfaced inline; 2 new agent docs for advanced patterns

---

## Metrics & Success Criteria

### Completed ✅

**v1.1.0:**
- ✅ All skill descriptions use forcing language
- ✅ File pattern metadata added to all skills
- ✅ skill-discovery meta-skill shipped

**v1.2.0:**
- ✅ Skills consolidated from 8 → 4
- ✅ RULES sections added to all skills
- ✅ MANDATORY language adopted
- ✅ CLAUDE.md template updated with enforcement section
- ✅ Skill reminder hook added

**v1.3.0:**
- ✅ `testing-essentials` skill added (RULES, TDD workflow, pattern skeletons)
- ✅ `testing-guide.md` refactored as reference companion with no duplication
- ✅ All 4 existing skills point to `testing-essentials` for test files
- ✅ Plugin stands alone without requiring external plugins for testing guidance

**v1.3.1:**
- ✅ `phoenix-liveview-essentials` rules #8 and #9 added (core components, DB query boundary)
- ✅ `CLAUDE.md.template` updated with HexDocs MCP note

**v1.3.2:**
- ✅ Setup Chaining section added to `testing-essentials`
- ✅ Timestamp Testing section added to `testing-essentials`
- ✅ `async: true` rule refined with safe/unsafe categorization
- ✅ Context Test Skeleton improved with result binding and error assertions

### Upcoming

**v1.4.0:** ✅
- ✅ 3 new hooks shipped (dangerous ops, debug detection, security reminder)
- ✅ otp-essentials skill with 7 RULES and comprehensive OTP patterns
- ✅ oban-essentials skill with 7 RULES and worker/testing patterns
- ✅ SubagentStart hook injects rules into all spawned subagents
- ✅ Total: 7 skills, 13 hooks, subagent enforcement

**v2.0.0 Success Metrics:**
- [ ] Detects 80%+ of code duplication cases
- [ ] Identifies 90%+ of high-complexity functions
- [ ] Saves 100+ lines per project on average
- [ ] Zero false positives in duplication detection

**v2.1.0 Success Metrics:**
- [ ] Auth implementation time reduced by 50%
- [ ] cast_assoc errors eliminated
- [ ] Pre-commit hooks prevent 80%+ of style issues
- [ ] Comprehensive Phoenix pattern coverage

**v2.2.0 Success Metrics:**
- [ ] Project detection reads mix.exs and caches stack info (Phoenix version, LiveView, Oban, Ecto adapter)
- [ ] Hooks conditionally apply based on detected stack (skip LiveView hooks for API-only projects)
- [ ] Unsafe migrations blocked before execution
- [ ] PostToolUse hooks catch context boundary violations and missing preloads

**v2.3.0 Success Metrics:**
- [ ] 6 new security hooks actively block insecure code (`String.to_atom` on input, unparameterized SQL, open redirects)
- [ ] deployment-gotchas covers the 7 things that break every first deploy
- [ ] Channels, telemetry, and JSON API skills fill remaining domain gaps
- [ ] Plugin enforces security, not just documents it — unique differentiator

**v3.0.0 Success Metrics:**
- [ ] 80%+ of common Elixir errors produce targeted fix guidance
- [ ] Credo issues surfaced inline without manual invocation
- [ ] Test failures analyzed with Phoenix-specific suggestions
- [ ] Compilation warnings converted to actionable items

---

## Key Insights

### What Makes This Different

Four complementary approaches working together:
1. **Proactive (Skills)** - Teach patterns upfront before mistakes happen
2. **Preventive (Hooks)** - Real-time warnings as code is written
3. **Enforced (Forcing Functions)** - Multiple touchpoints ensure skills are used
4. **Reactive (Error Guidance)** - Parse failures and surface targeted fixes (v3.0.0)

### What Worked Well

- **Consolidation** - Going from 8 → 4 skills reduced choice paralysis
- **RULES sections** - Non-negotiable rules visible in 10 seconds improved adoption
- **MANDATORY language** - Stronger than "INVOKE BEFORE" for discouraging rationalization
- **Multiple enforcement layers** - Skills + hooks + CLAUDE.md template + reminder hook

### What NOT to Do (Antipatterns)

- ❌ **Don't make skills too advisory** - Mandatory language works better
- ❌ **Don't create too many skills** - More choice = less adoption
- ❌ **Don't rely on users to discover** - Build automated triggers
- ❌ **Don't ignore consolidation** - Related skills should be merged, not kept separate

---

## Sources

This roadmap draws on:

1. **CHANGELOG.md** - Accurate record of what shipped in each version
2. **ELIXIR_PLUGIN_IMPROVEMENTS.md** - Real development experience from building a Phoenix app (7 weeks of session notes)
3. **elixir-optimization-plugin-refactoring.md** - Code duplication detection guide (~500 lines eliminated)
4. **elixir-optimization-plugin-feedback.md** - Root cause analysis of skill adoption failures
5. **Competitive analysis** - [oliver-kriska/claude-elixir-phoenix](https://github.com/oliver-kriska/claude-elixir-phoenix) (v2.3.1, March 2026) — identified gaps in OTP, Oban, security hooks, and subagent enforcement

---

**Maintainer Notes:**
- Keep this document updated as features are implemented
- Mark completed items with ✅
- Add new insights from ongoing development
- Review priorities quarterly based on user feedback