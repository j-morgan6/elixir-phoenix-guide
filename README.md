# Elixir Phoenix Guide for Claude Code

**Version:** 2.3.0 | [Changelog](CHANGELOG.md)

An essential development guide for Claude Code that ensures idiomatic Elixir and Phoenix LiveView code. This plugin includes enforced skills, context-aware hooks, automated code quality analysis, and agent documentation that actively guide and validate your Elixir development workflow.

> **v2.3.0 Released!** Expanded domains — security enforcement hooks, deployment gotchas, Phoenix Channels, telemetry/observability, and JSON API skills. See [CHANGELOG.md](CHANGELOG.md) for details.

## What's Included

### Skills (19 essential files)
Consolidated domain expertise with enforced patterns:
- **elixir-essentials** - Core Elixir patterns: pattern matching, pipes, with statements, error handling
- **phoenix-liveview-essentials** - Complete LiveView guide: lifecycle, events, rendering phases, state management
- **ecto-essentials** - Database operations: schemas, changesets, queries, migrations, associations
- **phoenix-uploads** - File uploads and static file serving workflow
- **testing-essentials** - Testing patterns: DataCase/ConnCase setup, fixtures, LiveView tests, TDD workflow
- **otp-essentials** - OTP patterns: GenServer, Supervisor, Task, Agent, DynamicSupervisor, Registry, ETS
- **oban-essentials** - Background jobs: workers, queues, idempotency, unique jobs, cron, testing with Oban.Testing
- **code-quality** - Automated code quality detection: duplication, complexity, unused functions
- **phoenix-liveview-auth** - LiveView authentication: on_mount, current_scope, import conflicts, session handling
- **ecto-changeset-patterns** - Advanced changesets: separate per operation, cast_assoc pitfalls, composition
- **phoenix-auth-customization** - Extending phx.gen.auth: custom fields, migrations, fixture updates
- **phoenix-pubsub-patterns** - Real-time updates: subscriptions, broadcasting from contexts, topic naming
- **phoenix-authorization-patterns** - Access control: server-side authz, ownership, policy modules, scoped queries
- **ecto-nested-associations** - Nested data: cast_assoc, cast_embed, Ecto.Multi, cascades, FK indexes
- **security-essentials** - Security enforcement: atom exhaustion, SQL injection, XSS, open redirects, timing attacks
- **deployment-gotchas** - Deployment pitfalls: runtime.exs, release migrations, PHX_HOST, health checks, secrets
- **phoenix-channels-essentials** - Channels: socket auth, topic authorization, Presence, handle_in patterns
- **telemetry-essentials** - Observability: structured logging, :telemetry, Ecto events, LiveDashboard, metrics
- **phoenix-json-api** - JSON APIs: :api pipeline, FallbackController, pagination, versioning, Bearer auth

Each skill includes a RULES section with 6-11 non-negotiable patterns that must be followed.

**Note on auto_suggest metadata:** Skills include `auto_suggest: true` and `file_patterns` metadata for future Claude Code enhancements. These fields are not currently active in the Claude Code runtime but are included for forward compatibility.

### Hooks (27 rules in settings.json)
Context-aware enforcement rules that adapt to your project stack:

**SessionStart (runs once per session):**
- **project-detection** - Parses `mix.exs` to detect Phoenix version, LiveView, Ecto adapter, Oban — hooks adapt behavior based on results

**Blocking (exit 2 - prevents action):**
- **missing-impl** - Blocks callbacks without @impl true (skips in API-only projects) — with fix suggestion
- **hardcoded-paths** - Blocks hardcoded file paths — with Application.get_env fix
- **hardcoded-sizes** - Blocks hardcoded file size limits — with config migration fix
- **static-paths-validator** - Blocks file references not in static_paths()
- **deprecated-components** - Blocks deprecated Phoenix components — context-aware: warns on @current_user in Phoenix 1.8+ projects
- **dangerous-operations** - Blocks mix ecto.reset, git push --force, MIX_ENV=prod
- **atom-from-user-input** - Blocks String.to_atom/1 — atom table exhaustion risk
- **unparameterized-sql-fragment** - Blocks string interpolation in Ecto fragment — SQL injection
- **unsafe-redirect** - Blocks redirect to user-controlled URLs — open redirect risk

**Warnings (exit 1 - shows warning with fix suggestion):**
- **nested-if-else** - Warns with case/multi-clause function fix
- **inefficient-enum** - Warns with for comprehension/reduce fix
- **string-concatenation** - Warns with IO list/Enum.join fix
- **auto-upload-warning** - Warns when auto_upload: true is detected (skips in API-only projects)
- **debug-statements** - Warns on IO.inspect, dbg(), IO.puts outside test files
- **migration-safety** - Checks for missing FK indexes, on_delete strategies, unsafe column operations
- **raw-html-warning** - Warns on raw/1 usage — XSS risk from unescaped HTML
- **sensitive-logging** - Warns on password/token/secret/api_key in Logger calls
- **timing-unsafe-compare** - Warns on == with tokens/secrets — suggests Plug.Crypto.secure_compare/2

**PostToolUse (runs after file write):**
- **code-quality-analysis** - Detects code duplication, ABC complexity >30, unused private functions (.ex/.exs) and template duplication (.heex)
- **missing-preload** - Warns on association accessors without visible preload
- **missing-error-clause** - Warns on `with` statements missing `else` clause
- **raw-sql-warning** - Blocks SQL injection patterns, warns on all raw SQL with parameterized query suggestions
- **context-boundary-violation** - Warns on direct Repo calls in LiveView modules (skips in API-only projects)

**Reminders (exit 0 - non-blocking nudge):**
- **security-audit** - Suggests mix deps.audit/hex.audit/sobelow when mix.exs changes

### Subagent Enforcement
- **SubagentStart hook** - Injects condensed rules from all 19 skills into every spawned subagent, ensuring code written by subagents follows the same standards

### Analysis Scripts (4 scripts)
Automated code quality analysis tools:
- **code_quality.exs** - AST-based Elixir analysis: duplication detection, ABC complexity, unused function detection
- **detect_template_duplication.sh** - HEEx template duplication detection
- **detect_project.sh** - Project stack detection for context-aware hooks
- **run_analysis.sh** - Full project analysis runner

### Agent Documentation (4 files)
Detailed reference material for complex tasks:
- **project-structure.md** - Directory layout and context boundaries
- **liveview-checklist.md** - Step-by-step LiveView development checklist
- **ecto-conventions.md** - Comprehensive Ecto patterns and best practices
- **testing-guide.md** - Testing patterns for contexts, LiveViews, and schemas

### Project Template
- **CLAUDE.md.template** - Project-specific instructions template

## Installation

> **Note:** Official marketplace publication is in progress. Once available, installation will be even simpler through the official Claude Code marketplace.

### Installing for the First Time

In a Claude Code session, use the interactive plugin manager:

```bash
# Step 1: Add the marketplace (first time only)
/plugin marketplace add j-morgan6/elixir-phoenix-guide

# Step 2: Open the interactive plugin manager
/plugin

# This opens an interactive menu where you can:
# - Select the elixir-phoenix-guide marketplace
# - Install the elixir-phoenix-guide plugin
# - Choose scope (user = all projects, project = current only)
# - Verify you have version 2.2.0 or higher
```

### Updating to Latest Version

If you already have the plugin installed:

```bash
# Open the interactive plugin manager
/plugin

# Select "Marketplaces" → "elixir-phoenix-guide" → "Update"
# Then update the plugin from the menu
# Verify version shows 2.2.0 or higher
```

**Latest Updates (v2.2.0):**
- Project detection: hooks now adapt to your project stack (Phoenix version, LiveView, Ecto, Oban)
- 4 new PostToolUse validation hooks: missing-preload, missing-error-clause, raw-sql-warning, context-boundary-violation
- All warning hooks upgraded with copy-pasteable auto-fix suggestions
- Context-aware: API-only projects skip LiveView hooks, Phoenix 1.8+ gets Scope guidance
- Total: 19 skills, 27 hooks, 4 analysis scripts, 4 agent docs

See [CHANGELOG.md](CHANGELOG.md) for full release notes and version history.

## Usage

Once installed, Claude Code will automatically:

1. **Load skills** based on code context - providing intelligent suggestions for Elixir patterns
2. **Enforce hooks** in real-time - catching anti-patterns as you write code
3. **Reference agent docs** when needed - accessing detailed information for complex tasks
4. **Follow CLAUDE.md** (if present) - respecting project-specific conventions

### Example Interactions

**Before (without optimization):**
```elixir
def process(user) do
  if user.status == :active do
    if user.role == :admin do
      :allowed
    else
      :denied
    end
  else
    :inactive
  end
end
```

**After (with hooks and skills):**
- Hook warns about nested if/else
- Skill suggests pattern matching
- Claude generates:

```elixir
def process(%{status: :active, role: :admin}), do: :allowed
def process(%{status: :active}), do: :denied
def process(_), do: :inactive
```

### Testing the Setup

1. Open a Phoenix/Elixir project in Claude Code
2. Ask Claude to create a LiveView
3. Observe:
   - Skills guide idiomatic implementation
   - Hooks catch anti-patterns (missing @impl, hardcoded values)
   - Agent docs provide detailed checklists

## What This Optimizes

### Code Quality
- **Blocks** callbacks without @impl true (prevents compilation)
- **Blocks** hardcoded file paths and sizes (prevents runtime issues)
- **Warns** about nested if/else (suggests pattern matching)
- **Warns** about inefficient Enum chains (suggests for comprehensions)
- **Warns** about string concatenation in loops (suggests IO lists)
- **Detects** code duplication across modules (>70% function similarity)
- **Detects** high ABC complexity functions (threshold: 30)
- **Detects** unused private functions after refactoring
- **Detects** template duplication in HEEx files (>40% identical markup)

### Developer Experience
- Proactive guidance on Elixir idioms
- Real-time feedback on code quality
- Detailed checklists for complex features
- Consistent conventions across projects
- Reduced iterations and corrections

### Learning
- Clear explanations of "why" not just "what"
- Links to relevant patterns and best practices
- Progressive disclosure of complexity
- Examples of idiomatic vs non-idiomatic code

## Why This Exists

This plugin was created to ensure Claude Code consistently produces idiomatic Elixir and Phoenix code by making best practices impossible to ignore, not just available. It combines enforced patterns, real-time validation, and comprehensive guidance for all Elixir development work.

## Project-Specific Setup

For project-specific instructions, you can create a `CLAUDE.md` file in your project root with:
- Your app name and description
- Project-specific contexts
- Custom commands and workflows
- Team conventions

This file will be automatically loaded by Claude Code when working in your project.

## File Structure

```
elixir-phoenix-guide/
├── README.md                          # This file
├── skills/                            # Elixir expertise (14 essential skills)
│   ├── elixir-essentials/SKILL.md
│   ├── phoenix-liveview-essentials/SKILL.md
│   ├── ecto-essentials/SKILL.md
│   ├── phoenix-uploads/SKILL.md
│   ├── testing-essentials/SKILL.md
│   ├── otp-essentials/SKILL.md
│   ├── oban-essentials/SKILL.md
│   ├── code-quality/SKILL.md
│   ├── phoenix-liveview-auth/SKILL.md
│   ├── ecto-changeset-patterns/SKILL.md
│   ├── phoenix-auth-customization/SKILL.md
│   ├── phoenix-pubsub-patterns/SKILL.md
│   ├── phoenix-authorization-patterns/SKILL.md
│   └── ecto-nested-associations/SKILL.md
├── scripts/                           # Analysis and detection scripts
│   ├── code_quality.exs              # AST-based Elixir analysis
│   ├── detect_project.sh             # Project stack detection
│   ├── detect_template_duplication.sh # HEEx template comparison
│   └── run_analysis.sh               # Full project analysis runner
├── hooks-settings.json                # Hook configuration
└── agents/                            # Reference documentation
    ├── project-structure.md
    ├── liveview-checklist.md
    ├── ecto-conventions.md
    └── testing-guide.md
```

## Requirements

- Claude Code CLI installed
- Elixir 1.15+ projects
- Phoenix 1.7+ (for LiveView features)

## Customization

After installation via the plugin manager, all configuration files are installed to `~/.claude/`:
- Skills: `~/.claude/skills/`
- Hooks: `~/.claude/settings.json`
- Agent docs: `~/.claude/agents/`

You can customize these files directly. Changes take effect after restarting Claude Code.

### Adding Custom Skills
Create new directories with `SKILL.md` files in `~/.claude/skills/`

### Modifying Existing Rules
Edit any skill or hook file - changes take effect on next Claude Code restart

## Checking Your Version

In a Claude Code session:
```bash
/plugin

# Or check version in the plugin list
# Navigate to your installed plugins and verify version 2.2.0 or higher
```

## Troubleshooting

### Plugin shows old version after update

The `/plugin` update command may not refresh its local cache automatically. If the version shown doesn't match the latest release, run:

```bash
cd ~/.claude/plugins/marketplaces/elixir-phoenix-guide && git pull
```

Then re-run `/plugin` and update the plugin from the menu.

## Uninstall

In a Claude Code session:
```bash
/plugin

# Navigate to installed plugins
# Select elixir-phoenix-guide and choose "Uninstall"
```

## Contributing

Contributions welcome! Areas for improvement:
- Additional Elixir patterns and anti-patterns
- More Phoenix-specific hooks
- OTP and GenServer guidance
- Testing patterns and best practices
- Real-world examples and case studies

## License

MIT

## Acknowledgments

Inspired by the [Optimizing Claude Code](https://mays.co/optimizing-claude-code) article by Steven Mays.

## Related Resources

- [Claude Code Documentation](https://code.claude.com/docs)
- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Phoenix Framework](https://www.phoenixframework.org/)
- [Credo (Static Analysis)](https://github.com/rrrene/credo)

---

**Note:** This configuration applies globally to all Elixir projects. For project-specific customizations, use the `CLAUDE.md.template` in your project root.
