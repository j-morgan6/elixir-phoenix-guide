# Maintainer tools

Nothing in this folder is used by the plugin at runtime. It ships with the
plugin only because Claude Code installs the whole repository.

| Tool | Purpose |
|---|---|
| `check_snippets.exs` | Parses every fenced `elixir`/`heex` block in `skills/` and flags patterns that regressed before (pre-1.8 auth names, removed APIs). Run it from inside a Phoenix 1.8 app so HEEx can be parsed — see the header of the file. Mark deliberately bad examples with `<!-- epg:bad -->` on the line before the fence. |
| `sync_copilot.sh` | Regenerates the GitHub Copilot port (a separate repo checked out at `copilot/`, gitignored here) from `skills/` and `scripts/`. |

Release checklist:

1. `bash tests/hooks/run_tests.sh && bash tests/code_quality/run_tests.sh && bash tests/packaging/run_tests.sh`
2. `check_snippets.exs` → 0 problems
3. Bump `VERSION`, `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` (the packaging test fails if they disagree); add the CHANGELOG entry
4. `dev/sync_copilot.sh`, review `cd copilot && git diff`, bump the Copilot CHANGELOG
