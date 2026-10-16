# Maintainer tools

Nothing in this folder is used by the plugin at runtime. It ships with the
plugin only because Claude Code installs the whole repository.

| Tool | Purpose |
|---|---|
| `check_snippets.exs` | Parses every fenced `elixir`/`heex` block in `skills/` and flags patterns that regressed before (pre-1.8 auth names, removed APIs). Run it from inside a Phoenix 1.8 app so HEEx can be parsed — see the header of the file. Mark deliberately bad examples with `<!-- epg:bad -->` on the line before the fence. |
| `../evals/triggers/` | Skill-trigger evals for `claude plugin eval`: one case per realistic prompt, asserting which skill Claude invokes (and, for a few, which sibling it must not), plus non-Elixir prompts that must invoke none. Run: `claude plugin eval . --tag trigger --runs 2 --ablation none -j 4 --no-publish --trust-plugin`. Each run is a real Claude session (on a claude.ai plan it uses your usage allowance; with an API key it bills). Re-run after changing any skill `description`. |
| `sync_copilot.sh` | Regenerates the GitHub Copilot port (a separate repo checked out at `copilot/`, gitignored here) from `skills/` and `scripts/`. |

CI (`.github/workflows/ci.yml`) runs steps 1 and 2 on every push to `main` and every pull request: the hook and packaging suites on Ubuntu and macOS (`/bin/bash` 3.2), shellcheck, the `code_quality.exs` suite, and the snippet checker inside a freshly generated Phoenix app.

Release checklist:

1. `bash tests/hooks/run_tests.sh && bash tests/code_quality/run_tests.sh && bash tests/packaging/run_tests.sh`
2. `check_snippets.exs` → 0 problems
3. If any skill description changed: the trigger evals (see above) → every case passes
4. Bump `VERSION`, `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` (the packaging test fails if they disagree); add the CHANGELOG entry
5. `dev/sync_copilot.sh`, review `cd copilot && git diff`, bump the Copilot CHANGELOG
