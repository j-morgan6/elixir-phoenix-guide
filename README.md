# Elixir Phoenix Guide for Claude Code and Codex

[Changelog](CHANGELOG.md)

A Claude Code plugin (with Codex support for the skills) that keeps Claude's Elixir and Phoenix code idiomatic and current. It ships 19 skills checked against Phoenix 1.8's generators, plugin-native hooks that catch dangerous commands and risky code as Claude writes it, and on-demand analysis scripts.

> **v2.5.0** — every skill re-verified against Elixir 1.20, Phoenix 1.8.15, LiveView 1.2.12, Ecto 3.14 and Oban 2.24: Phoenix 1.8 scopes on every context call, secure upload/PubSub/API examples, forms and async in LiveView, and hooks that only report the lines Claude changed. See [CHANGELOG.md](CHANGELOG.md).

## What's Included

### Skills (19)
Each skill opens with a RULES section and a "Verified against" line naming the library versions it was checked against. Skills load on demand when Claude's task matches their description.

- **elixir-essentials** - Pattern matching, `with`, error contracts, modern Elixir (1.18+): type checker, `JSON`, `dbg`; Phoenix project layout reference
- **phoenix-liveview-essentials** - Lifecycle, forms (`to_form`, `phx-change`), streams, `assign_async`/`start_async`, JS commands, colocated hooks; LiveView checklist and JS interop references
- **ecto-essentials** - Scoped context functions, schemas, queries, migrations, upserts, `Repo.transact`; Ecto reference
- **phoenix-uploads** - `allow_upload`, content-type allowlists, magic-byte checks, external uploads, authorized downloads
- **testing-essentials** - DataCase/ConnCase, generated fixtures and scopes, LiveView helpers, Mox, `Req.Test`; testing reference
- **otp-essentials** - GenServer, Supervisor, Task, Registry, ETS, PartitionSupervisor, timeouts
- **oban-essentials** - Workers, uniqueness, transactional enqueue, Oban 2.24 plugin config, Lifeline, Oban.Testing
- **code-quality** - Compiler and Credo first, then on-demand duplication and branch-complexity scans
- **phoenix-liveview-auth** - The generated `UserAuth`: `on_mount`, `live_session`, `mount_current_scope`, sudo mode, logout disconnects
- **ecto-changeset-patterns** - Separate changesets per operation, password/email rules, never casting privileged fields
- **phoenix-auth-customization** - Adding fields to the phx.gen.auth user, registration changeset, fixtures
- **phoenix-pubsub-patterns** - Scoped topics, broadcasting from contexts, streams in `handle_info`, Presence in LiveView
- **phoenix-authorization-patterns** - `%Scope{}`-first contexts, ownership checks, policies, mass-assignment safety
- **ecto-nested-associations** - `cast_assoc`/`cast_embed`, `inputs_for` sort/drop params, `on_replace`, cascades, Multi
- **security-essentials** - Injection, XSS, SSRF, open redirects (`external:`), CSP, safe deserialization, Sobelow
- **deployment-gotchas** - `mix phx.gen.release --docker`, runtime.exs, release migrations, SSL, rolling deploys, health checks
- **phoenix-channels-essentials** - Socket auth and tokens, join authorization, `intercept`/`handle_out`, Presence
- **telemetry-essentials** - Logger metadata, telemetry handlers, metric tag cardinality, OpenTelemetry, LiveDashboard
- **phoenix-json-api** - phx.gen.json-style JSON views, FallbackController, keyset pagination, hashed API tokens, rate limits

Longer reference material lives next to the skill that uses it (`skills/<skill>/*.md`) and Claude reads it only when needed.

### Hooks (ship inside the plugin)
Hooks live in `hooks/hooks.json` and activate when the plugin is installed. They need `jq`.

| Event | Check | Result |
|---|---|---|
| SessionStart | Project summary for Claude: Phoenix/LiveView versions (locked and required), scopes, Ecto adapter, Oban, umbrella apps; warns when `jq` is missing | context |
| PreToolUse (Bash) | `mix ecto.reset` / `mix ecto.drop` unless `MIX_ENV=test` | block |
| PreToolUse (Bash) | `git push --force`, `-f`, `-uf`, `+refspec` (`--force-with-lease` and `--force-if-includes` allowed) | block |
| PostToolUse (Write/Edit) | Interpolated SQL in `Repo.query`/`SQL.query` or `fragment()`; `redirect(external: params…)`; removed/deprecated APIs (`form_for`, `live_redirect`, `live_patch`, `push_redirect`) | block |
| PostToolUse (Write/Edit) | `String.to_atom/1`, `raw/1`, Logger interpolating secrets, `IO.inspect`/`dbg`, timing-unsafe `==` on secrets, missing `@impl true`, migration FK without index or `on_delete`, `@current_user` in a scopes app | review |

- **block** — exit 2 with the reason on stderr; Claude must deal with it (for Bash, the command doesn't run).
- **review** — an advisory note (`additionalContext`); Claude decides, nothing is blocked.
- File checks report **only the lines that tool call changed**, ignore comments and `@doc` text, and skip tests, `deps/`, `_build/` and `node_modules/`.
- The Bash guard runs only in Elixir projects. To run a blocked command deliberately, prefix it with `EPG_ALLOW=force_push` (or `ecto_reset`, `ecto_drop`) or set that variable in Claude Code's environment.

See [INSTALL-HOOKS.md](INSTALL-HOOKS.md) for details and known limits.

### Analysis Scripts
Shipped with the plugin under `scripts/` and run on demand (the `code-quality` skill tells Claude how):
- **code_quality.exs** - Duplicate function bodies across the whole tree (names and variables ignored) and branch complexity. For unused code, use `mix compile --warnings-as-errors` and `mix xref`.
- **run_analysis.sh** - Runs the scans over `lib/` (or `apps/*/lib` in an umbrella)
- **detect_project.sh** - Project stack detection used by the SessionStart hook

### Project Template
- **CLAUDE.md.template** - Project-specific instructions template

## Installation

> **Note:** Official marketplace publication is in progress. Once available, installation will be even simpler through the official Claude Code marketplace.

### Installing for the First Time

In a Claude Code session:

```bash
# Step 1: Add the marketplace (first time only)
/plugin marketplace add j-morgan6/elixir-phoenix-guide

# Step 2: Install the plugin
/plugin install elixir-phoenix-guide@elixir-phoenix-guide
```

Skills and hooks activate automatically — nothing else to configure. Optional extras (the `CLAUDE.md` project template, cleanup of legacy pre-2.4.0 installs) are available via `./install.sh` from a checkout:

```bash
git clone https://github.com/j-morgan6/elixir-phoenix-guide.git
cd elixir-phoenix-guide
./install.sh
```

### Codex

The skills also work in OpenAI Codex (hooks are Claude Code only). Either load the repo as a Codex plugin through `.codex-plugin/plugin.json`, or install the skills for the current user from a checkout:

```bash
git clone https://github.com/j-morgan6/elixir-phoenix-guide.git
cd elixir-phoenix-guide
./install-codex.sh
```

This copies every skill directory (including its reference files) into `${CODEX_HOME:-~/.codex}/skills` and points the `code-quality` skill at this checkout's `scripts/`, so keep the checkout. Re-run it after `git pull` to update, then restart Codex.

### Updating to Latest Version

If you already have the plugin installed:

```bash
# Open the interactive plugin manager
/plugin

# Select "Marketplaces" → "elixir-phoenix-guide" → "Update"
# Then update the plugin from the menu
```

See [CHANGELOG.md](CHANGELOG.md) for full release notes and version history.

## Usage

Once installed, Claude Code will automatically:

1. **Load skills** when the task matches a skill's description
2. **Run hooks** on Bash commands and file writes - blocking dangerous commands and flagging risky code
3. **Read a skill's reference files** when a task needs the detail
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

**After (with skills guiding idiomatic Elixir):**
- Skill suggests pattern matching over nested conditionals
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
   - Hooks flag anti-patterns in the lines Claude wrote (missing @impl, security issues, Phoenix deprecations)
   - The LiveView checklist is used before finishing

## What This Optimizes

### Code Quality
- **Blocks** destructive Bash commands (`mix ecto.reset`/`ecto.drop` outside test, force pushes)
- **Blocks** near-certain bugs in written code: SQL built by interpolation, `redirect(external:)` from params, removed Phoenix APIs
- **Flags** for review: `String.to_atom/1`, `raw/1`, secrets in Logger interpolation, timing-unsafe comparisons, debug calls, missing `@impl true`, migration FK indexes and `on_delete`, `@current_user` in scope-based apps
- **Scans** on demand for duplicated function bodies and branch complexity

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
├── INSTALL-HOOKS.md                   # Hook behavior reference
├── CLAUDE.md.template                 # Project-specific instructions template
├── install.sh                         # Optional extras: CLAUDE.md template + legacy cleanup
├── install-codex.sh                   # Installs the skills for OpenAI Codex
├── .codex-plugin/plugin.json          # Codex plugin manifest
├── VERSION                            # Plugin version (also in both plugin.json manifests)
├── skills/                            # 19 skills; some carry reference files
│   ├── elixir-essentials/             # SKILL.md, project-structure.md
│   ├── phoenix-liveview-essentials/   # SKILL.md, checklist.md, js-interop.md
│   ├── ecto-essentials/               # SKILL.md, reference.md
│   ├── testing-essentials/            # SKILL.md, reference.md
│   └── …                              # 15 more, SKILL.md each
├── hooks/
│   └── hooks.json                     # SessionStart + PreToolUse + PostToolUse config
├── scripts/                           # Shipped with the plugin
│   ├── code_quality.exs               # Duplication + branch complexity (on demand)
│   ├── detect_project.sh              # Project stack detection (SessionStart)
│   ├── run_analysis.sh                # Analysis runner (on demand)
│   ├── lib/common.sh                  # Shared shell helpers
│   └── hooks/
│       ├── bash_guard.sh              # PreToolUse (Bash)
│       └── check_file.sh              # PostToolUse (Write|Edit|MultiEdit)
├── tests/
│   ├── hooks/run_tests.sh             # Hook test harness (fixture-based)
│   ├── code_quality/run_tests.sh      # code_quality.exs test harness
│   └── packaging/run_tests.sh         # Version agreement + install-codex.sh checks
└── dev/                               # Maintainer tools (not used at runtime)
    ├── check_snippets.exs             # Parses every elixir/heex block in skills/
    └── sync_copilot.sh                # Regenerates the GitHub Copilot port
```

## Requirements

- Claude Code
- `jq` (for the hooks)
- Skills target Elixir 1.18+, Phoenix 1.8, LiveView 1.1+, Ecto 3.13+ and Oban 2.20+; most guidance still applies to Phoenix 1.7 apps, but the auth, scope and generator examples assume 1.8

## Customization

The plugin manager keeps a copy of each installed version under
`~/.claude/plugins/cache/<marketplace>/elixir-phoenix-guide/<version>/` and runs
skills, hooks and scripts from there (`${CLAUDE_PLUGIN_ROOT}`). It does not copy
files into `~/.claude/skills/` or merge anything into `~/.claude/settings.json`.
Plugin updates replace that copy, so don't edit it by hand:

- **Project-specific rules** go in your project's `CLAUDE.md` (see the template).
- **Extra hooks** go in your project's `.claude/settings.json`; they run alongside the plugin's.
- **Changing skills or the plugin's hooks**: fork the repo and install from your fork.

## Checking Your Version

In a Claude Code session:
```bash
/plugin

# Navigate to your installed plugins; the version is shown there
# (and in the cache path: ~/.claude/plugins/cache/<marketplace>/elixir-phoenix-guide/<version>/)
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

**Note:** Once installed, the plugin is active in every project you open. Its skills only load for Elixir work, and the hooks do nothing outside Elixir projects (no `mix.exs`). For project-specific customizations, use the `CLAUDE.md.template` in your project root.
