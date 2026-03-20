# Changelog

All notable changes to the Elixir Phoenix Guide plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Expanded domains: security hooks, deployment gotchas, channels, telemetry, JSON API (v2.3.0)

## [2.2.0] - 2026-03-20

### Added
- **Project Detection System** — SessionStart hook that parses `mix.exs` and caches project characteristics:
  - Phoenix version (1.7 vs 1.8+ Scope struct detection)
  - LiveView presence (API-only vs full-stack)
  - Ecto adapter (Postgres, SQLite, MySQL, or none)
  - Oban presence
  - Cache written to `.elixir-phoenix-guide-project.json` in project root
- **`detect_project.sh` script** — project detection engine used by SessionStart hook
- **4 new PostToolUse validation hooks:**
  - **missing-preload** — warns when association accessors are found without visible preload calls
  - **missing-error-clause** — warns when `with` statements lack an `else` clause for error handling
  - **raw-sql-warning** — blocks string interpolation in raw SQL (SQL injection), warns on all raw SQL usage with parameterized query suggestions
  - **context-boundary-violation** — warns when `Repo` is called directly in LiveView modules instead of through context functions

### Changed
- **Hook count:** 15 → 21 (1 SessionStart + 4 PostToolUse + 1 context-aware upgrade)
- **All warning hooks upgraded with auto-fix suggestions:**
  - **nested-if-else** — now suggests `case` tuple matching and multi-clause functions with copy-pasteable examples
  - **inefficient-enum** — now suggests `for` comprehensions and `Enum.reduce` with examples
  - **string-concatenation** — now suggests IO lists and `Enum.join` with examples
  - **missing-impl** — now shows exact `@impl true` placement with example
  - **hardcoded-paths** — now shows `Application.get_env` migration pattern
  - **hardcoded-sizes** — now shows config-based size limit pattern
- **Context-aware hooks** — hooks now read `.elixir-phoenix-guide-project.json` cache:
  - **skill-reminder** — notes API-only projects when LiveView is absent
  - **missing-impl** — skips LiveView callback checks in API-only projects
  - **deprecated-components** — warns on `@current_user` in Phoenix 1.8+ projects (should use `@current_scope`)
  - **auto-upload-warning** — skips entirely in API-only projects
  - **context-boundary-violation** — skips in API-only projects
- **install.sh** — now installs `detect_project.sh` alongside other analysis scripts

### Impact
- Hooks adapt to project stack — API-only projects won't see irrelevant LiveView warnings
- Phoenix 1.8 users get Scope-aware guidance automatically
- PostToolUse validation catches architectural issues (context violations, missing preloads) after code is written
- Auto-fix suggestions reduce round-trips — developers can copy-paste the suggested fix directly
- Project detection runs once per session and caches results for all hooks to read

## [2.1.0] - 2026-03-19

### Added
- **`phoenix-liveview-auth` skill** — 7 RULES covering on_mount callbacks, current_scope vs current_user, import conflict resolution, session token extraction, bracket access safety, auth redirect testing, live_session router integration
- **`ecto-changeset-patterns` skill** — 7 RULES covering separate named changesets per operation, cast_assoc foreign key pitfalls, changeset composition with pipes, unsafe_validate_unique pairing, update_change transforms, conditional validation with opts, changeset-level validation
- **`phoenix-auth-customization` skill** — 6 RULES covering extending phx.gen.auth with custom fields, separate migrations, registration_changeset updates, test fixture maintenance, user confirmation in fixtures
- **`phoenix-pubsub-patterns` skill** — 6 RULES covering connected? guard for subscriptions, broadcasting from contexts, topic naming conventions, handle_info for PubSub, immutable assign updates, full-cycle testing
- **`phoenix-authorization-patterns` skill** — 6 RULES covering server-side authorization in event handlers, ownership verification, policy modules, data-confirm for destructive actions, scoped context queries, unauthorized path testing
- **`ecto-nested-associations` skill** — 6 RULES covering cast_assoc for has_many/has_one, Ecto.Multi for multi-table operations, on_delete cascade strategies, FK indexes, on_replace: :delete, preloading before updates
- **`migration-safety` hook** (Write/Edit, exit 1) — checks migration files for missing FK indexes, missing on_delete strategies, unsafe column removals, NOT NULL without defaults

### Changed
- **Skill count:** 8 → 14 (6 new skills covering auth, changesets, PubSub, authorization, nested associations)
- **Hook count:** 14 → 15 (new migration safety hook)
- **SubagentStart hook** — updated to inject condensed rules from all 14 skills
- **CLAUDE.md.template** — updated with 6 new skill references and migration-safety hook

### Impact
- Comprehensive coverage of Phoenix authentication, authorization, and data patterns
- Battle-tested skills based on real-world debugging sessions (30-90 min pain points each)
- Migration safety catches common deployment-breaking issues before they're committed
- All new skill rules enforced in subagents via updated SubagentStart hook

## [2.0.0] - 2026-03-16

### Added
- **`code-quality` skill** — 7 RULES covering code duplication, ABC complexity, unused functions, template duplication, and refactoring guidance
- **PostToolUse code quality hook** (Write/Edit) — automatically analyzes files after they're written:
  - `.ex`/`.exs` files: duplication detection, ABC complexity analysis, unused private function detection
  - `.heex` files: template duplication detection
- **`code_quality.exs` script** — AST-based Elixir analysis engine:
  - **Code duplication detection** — parses function bodies using `Macro.to_string/1`, compares with trigram similarity, flags matches >70% across sibling modules
  - **ABC complexity analyzer** — counts Assignments (`=`), Branches (`case`, `cond`, `if`, `with`, `->`), Conditions (`&&`, `||`, `==`, `when`, etc.), flags functions with ABC > 30
  - **Unused function detection** — finds `defp` functions never called within their module
  - Supports single-file analysis (`all <file>`) and full project scan (`scan <directory>`)
- **`detect_template_duplication.sh` script** — detects HEEx templates sharing >40% identical markup in the same directory
- **`run_analysis.sh` script** — full project analysis runner combining all checks

### Changed
- **Skill count:** 7 → 8 (new code-quality skill)
- **Hook count:** 13 → 14 (new PostToolUse code quality analyzer)
- **install.sh** — now installs analysis scripts to `~/.claude/scripts/elixir-phoenix-guide/`
- **CLAUDE.md.template** — updated with code-quality skill reference and automation section
- **SubagentStart hook** — updated to reference 8 skills

### Impact
- Major version bump: first automation features that go beyond skill/hook guidance
- Based on analysis showing ~500+ lines of duplicated code eliminated through systematic refactoring in real Phoenix projects
- PostToolUse hooks provide real-time feedback after every file write without blocking the action
- On-demand full project scanning via `run_analysis.sh` for CI/CD integration

## [1.4.0] - 2026-03-13

### Added
- **`otp-essentials` skill** — 7 RULES covering GenServer, Supervisor, Task, Agent, DynamicSupervisor, Registry, ETS, and common OTP anti-patterns
- **`oban-essentials` skill** — 7 RULES covering workers, queues, idempotency, unique jobs, cron scheduling, testing with Oban.Testing, and error handling
- **`dangerous-operations-blocker` hook** (Bash, exit 2) — blocks `mix ecto.reset`, `git push --force`, and `MIX_ENV=prod` commands
- **`debug-statement-detector` hook** (Write/Edit, exit 1) — warns on `IO.inspect`, `dbg()`, `IO.puts` outside test files
- **`security-audit-reminder` hook** (Write/Edit, exit 0) — nudges `mix deps.audit` / `hex.audit` / `sobelow` when `mix.exs` is modified
- **SubagentStart hook** — injects condensed rules from all 7 skills into every spawned subagent

### Impact
- Skill count: 5 → 7 (OTP and Oban coverage fills the biggest domain gaps)
- Hook count: 10 → 13 (first Bash-level hook, first PostToolUse-style detection)
- Subagent enforcement: code written by subagents now follows the same rules as the main conversation
- Motivated by competitive analysis of oliver-kriska/claude-elixir-phoenix (v2.3.1)

## [1.3.2] - 2026-03-08

### Changed
- **`testing-essentials`** — 4 targeted refinements:
  - **Setup Chaining section** — guidance on composing named setup functions with `setup [:func1, :func2]` for reusable test context
  - **Timestamp Testing section** — guidance on relative timestamps instead of hardcoded dates that cause flaky tests
  - **Refined `async: true` rule** — replaced one-liner with safe/unsafe categorization (safe: pure functions, changesets, helpers; unsafe: DB contexts, LiveView, `Application.put_env`)
  - **Improved Context Test Skeleton** — result bound to variable for further assertions, error case pattern matches changeset and checks `errors_on/1`

## [1.3.1] - 2026-03-04

### Added
- **`phoenix-liveview-essentials`** — 2 new rules:
  - Rule #8: Check `core_components.ex` for existing components before creating custom ones
  - Rule #9: Never query the database directly from LiveViews — call context functions instead
- **`CLAUDE.md.template`** — HexDocs MCP note added to "Notes for Claude" section

## [1.3.0] - 2026-02-22

### Added
- **`testing-essentials` skill** — proactive testing guidance invoked before any `_test.exs` file:
  - 8 non-negotiable RULES covering setup (DataCase/ConnCase), coverage, and assertion patterns
  - Light TDD guidance: write failing test first, implement until it passes
  - Quick pattern reference: DataCase/ConnCase setup, fixture skeleton, LiveView and context test skeletons
  - Pointer to `testing-guide.md` for comprehensive examples

### Changed
- **`testing-guide.md` refactored** into a deep reference companion:
  - Added header pointing to `testing-essentials` skill
  - Removed DataCase/ConnCase setup templates (now in skill)
  - Retained all detailed code examples
- **All 4 existing skills updated** with pointers to `testing-essentials` for test files:
  - `elixir-essentials`, `phoenix-liveview-essentials` (replaced testing section), `ecto-essentials`, `phoenix-uploads`

### Impact
- Plugin now provides complete testing guidance without relying on external plugins
- No duplication between skill and agent doc
- Testing skill surfaced automatically when any `_test.exs` file is written

## [1.2.0] - 2026-02-12

### Breaking Changes
- **Plugin renamed** from `elixir-optimization` to `elixir-phoenix-guide`
  - Better reflects purpose: essential guide for ALL Elixir work, not just optimization
  - Update marketplace references and installation commands
  - Reinstall required for existing users

### Changed
- **Skills consolidated from 8 to 4** for reduced friction:
  - `elixir-essentials` (merged elixir-patterns + error-handling)
  - `phoenix-liveview-essentials` (merged phoenix-liveview + liveview-lifecycle)
  - `ecto-essentials` (renamed from ecto-database)
  - `phoenix-uploads` (merged in phoenix-static-files content)
  - Removed skill-discovery meta-skill (no longer needed)

- **RULES sections added** to all skills:
  - 7-8 non-negotiable rules at the top of each skill
  - Rules visible in 10 seconds, reference examples below
  - Agents internalize rules, reference examples when needed

- **Skill descriptions shortened and strengthened**:
  - Changed from "INVOKE BEFORE" to "MANDATORY for ALL"
  - Removed feature lists that enable rationalization
  - Single-sentence descriptions using forceful language
  - Example: "MANDATORY for ALL Elixir code changes. Invoke before writing any .ex or .exs file."

- **CLAUDE.md template updated** with enforcement section:
  - Mandatory rules block added to template
  - Specifies exact skill invocation requirements per file type
  - Explicit "not optional" language
  - Projects adopting template get built-in enforcement

- **Reminder hook added**:
  - Non-blocking (exit 0) reminder on .ex/.exs/.heex writes
  - Prompts agent to verify skill invocation
  - Gentle nudge without preventing work

### Documentation
- **Metadata limitations documented**:
  - README now clarifies auto_suggest and file_patterns are forward-looking
  - Noted as pending Claude Code runtime support
  - False expectation claims removed from v1.1.0 changelog references

### Impact
- Reduced cognitive load: 4 skills vs 8 means less choice paralysis
- Improved adoption: MANDATORY language harder to rationalize away
- Better enforcement: CLAUDE.md template + hooks + reminders create multiple touchpoints
- Clearer purpose: "guide" name indicates this applies to ALL work, not just performance tuning

### Migration Notes
For existing users:
1. Uninstall `elixir-optimization` plugin
2. Install new `elixir-phoenix-guide` plugin from marketplace
3. Update project CLAUDE.md files if using template
4. Skill invocations use new names with same plugin prefix

## [1.1.0] - 2026-02-09

### Added
- **skill-discovery meta-skill** - Systematic checklist for identifying applicable skills
  - File type detection for automatic skill suggestion
  - Task type detection for process skills
  - Priority-ordered skill invocation guide
  - Example workflows for common scenarios
  - Marked as priority 1 skill to invoke first

### Changed
- **All 7 existing skills updated** with mandatory "INVOKE BEFORE" language:
  - elixir-patterns: "INVOKE BEFORE writing any Elixir code"
  - phoenix-liveview: "INVOKE BEFORE implementing any LiveView feature"
  - ecto-database: "INVOKE BEFORE modifying any Ecto schema, query, or migration"
  - error-handling: "INVOKE BEFORE implementing error handling"
  - phoenix-uploads: "INVOKE BEFORE implementing file upload functionality"
  - phoenix-static-files: "INVOKE BEFORE serving uploaded files or static content"
  - liveview-lifecycle: "INVOKE BEFORE working with LiveView rendering phases"

- **File pattern metadata added** to all skills:
  - Skills now include file_patterns array for automatic detection
  - auto_suggest: true flag enables proactive skill suggestions
  - Pattern matching for .ex, .exs, .heex files and specific directories

### Impact
- Expected 50%+ increase in skill usage through forcing language
- Automatic skill suggestions when editing relevant files
- Systematic skill discovery prevents missing applicable guidance
- Better developer experience with proactive skill recommendations

## [1.0.0] - 2026-01-26

### Added
- **7 Skills** for Elixir and Phoenix development:
  - `elixir-patterns` - Pattern matching, pipes, with statements, naming conventions
  - `phoenix-liveview` - LiveView lifecycle, events, uploads, PubSub, navigation
  - `ecto-database` - Schemas, changesets, queries, associations, migrations
  - `error-handling` - Error tuples, with statements, supervisors, error boundaries
  - `phoenix-uploads` - File upload configuration, manual vs auto-upload patterns
  - `phoenix-static-files` - Static paths configuration and file serving
  - `liveview-lifecycle` - Render phases, safe assign access, mount initialization

- **10 Hooks** for real-time code quality enforcement:
  - Blocking hooks (5): missing-impl, hardcoded-paths, hardcoded-sizes, static-paths-validator, deprecated-components
  - Warning hooks (4): nested-if-else, inefficient-enum, string-concatenation, auto-upload-warning

- **4 Agent Documentation Files**:
  - `project-structure.md` - Directory layout and context boundaries
  - `liveview-checklist.md` - Step-by-step LiveView development guide
  - `ecto-conventions.md` - Comprehensive Ecto patterns and best practices
  - `testing-guide.md` - Testing patterns for contexts, LiveViews, and schemas

- **Installation Methods**:
  - Claude Code plugin marketplace installation
  - Quick install script
  - Manual installation guide

- **Project Template**:
  - CLAUDE.md.template for project-specific customization

### Documentation
- Comprehensive README with installation and usage instructions
- Hook installation guide (INSTALL-HOOKS.md)
- MIT License
- Installation script (install.sh)

---

## Version History Summary

| Version | Date | Description |
|---------|------|-------------|
| v2.2.0 | 2026-03-20 | Smart enforcement — project detection, context-aware hooks, PostToolUse validation, auto-fix suggestions |
| v2.1.0 | 2026-03-19 | Additional skills & polish — auth, changesets, PubSub, authorization, nested associations, migration safety |
| v2.0.0 | 2026-03-16 | Automation — code duplication, complexity, unused functions, template duplication |
| v1.4.0 | 2026-03-13 | Competitive parity — OTP skill, Oban skill, 3 new hooks, subagent enforcement |
| v1.3.2 | 2026-03-08 | Testing essentials refinements — setup chaining, timestamps, async, skeletons |
| v1.3.1 | 2026-03-04 | LiveView rules + template refinements |
| v1.3.0 | 2026-02-22 | Testing skill — testing-essentials + agent doc refactor |
| v1.2.0 | 2026-02-12 | Consolidation & enforcement — 4 skills, RULES sections, MANDATORY language |
| v1.1.0 | 2026-02-09 | Skill discoverability — forcing language, file patterns, skill-discovery meta-skill |
| v1.0.0 | 2026-01-26 | Initial release with 7 skills, 10 hooks, and 4 agent docs |

---

## Upgrade Guide

### From No Configuration → v1.0.0
Install using any of the three methods in README.md. No migration needed.

---

## Future Versions (Planned)

### v2.3.0 - Expanded Domains
**Focus:** Security hooks, deployment gotchas, channels, telemetry, JSON API

### v3.0.0 - Reactive Intelligence
**Focus:** Error decoder, test failure analyzer, Credo integration

---

[Unreleased]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.4.0...v2.0.0
[1.4.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.3.2...v1.4.0
[1.3.2]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.1.2...v1.2.0
[1.1.0]: https://github.com/j-morgan6/elixir-phoenix-guide/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/j-morgan6/elixir-phoenix-guide/releases/tag/v1.0.0
