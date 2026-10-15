# Hooks

Hooks ship **inside the plugin** (`hooks/hooks.json`) and activate
automatically when you install it:

```
/plugin marketplace add j-morgan6/elixir-phoenix-guide
/plugin install elixir-phoenix-guide@elixir-phoenix-guide
```

No settings.json editing, no script copying.

## Requirements

- **`jq`** for the Bash guard and the file checks (`brew install jq`,
  `apt-get install jq`, `apk add jq`). Without it those two hooks do nothing,
  and the SessionStart summary says so in Elixir projects:
  `jq not found — file and Bash checks are disabled. Install jq to enable them.`
- `git` (optional) lets the file check limit `Write` findings to the lines that
  changed.

Everything is plain bash + awk (macOS bash 3.2 compatible). Nothing runs `mix`
or compiles code; a file check takes about 30–50 ms.

## What runs

| Event | Check | Result |
|---|---|---|
| SessionStart | One-line project summary for Claude: Phoenix and LiveView versions (locked version from `mix.lock`, plus the `mix.exs` requirement), whether the app uses Phoenix 1.8 scopes, Ecto adapter, Oban, umbrella apps. Caches `phoenix_has_scope` in the plugin data dir (never your repo). Silent outside Elixir projects | context |
| PreToolUse (Bash) | `mix ecto.reset` / `mix ecto.drop` unless `MIX_ENV=test` | block |
| PreToolUse (Bash) | `git push --force`, `-f`, combined flags such as `-uf`, `+refspec` (allows `--force-with-lease`, `--force-if-includes`) | block |
| PostToolUse (Write/Edit/MultiEdit) | SQL built by interpolation in `Repo.query`/`SQL.query` (string or heredoc; `#{@attr}` allowed) | block |
| | Interpolation inside `fragment()` | block |
| | `redirect(external: params…)` (open redirect) | block |
| | `form_for` (removed in phoenix_html 4) | block |
| | `live_redirect`, `live_patch`, `push_redirect` (deprecated) | block |
| | `String.to_atom/1` | review |
| | `raw/1`, `Phoenix.HTML.raw/1` | review |
| | Logger message interpolating a sensitive name (`#{…password…}`, token, secret, api_key, private_key, credential, authorization) | review |
| | `IO.inspect` / `dbg` in `.ex` files (not in `mix/tasks/`) | review |
| | `==` on token/secret/api_key/signature (use `Plug.Crypto.secure_compare/2`) | review |
| | Callback (`mount`, `handle_*`, `terminate`) without `@impl true` on its first clause | review |
| | Migration `references()` column with no index on that table in the same migration | review |
| | Migration `references()` without `on_delete:` | review |
| | `@current_user` in a project that uses scopes (Scope module or `current_scope` in `user_auth.ex`) | review |

**block**: exit 2 with the reason on stderr. Claude Code shows it to Claude,
which has to deal with it. For PreToolUse the command doesn't run.
**review**: exit 0 with `hookSpecificOutput.additionalContext` JSON. Claude
sees the note and decides; nothing is blocked.

## How the file check decides what to report

- **Only the lines this tool call changed are reported**, so findings in code
  Claude didn't touch never come back:
  - `Edit` / `MultiEdit`: the lines where `new_string` now sits in the file
    (every occurrence; if a formatter changed it, lines whose trimmed text
    matches). An edit that only deletes reports nothing.
  - `Write`: the added lines from `git diff` when the file is tracked;
    otherwise (new or untracked file, no git) the whole file.
- **Findings are evaluated with the whole file as context**: a later clause of
  a callback whose first clause has `@impl true` is fine; a migration index
  added further down the file counts for its table.
- `#` comments, `@moduledoc`/`@doc`/`@typedoc` text and HEEx comments
  (`<%!-- --%>`, `<!-- -->`) are ignored.
- Skipped: test files (`*_test.exs`, `test/`), `deps/`, `_build/`,
  `node_modules/`, `.elixir_ls/`.

## The Bash guard

- Runs only in Elixir projects: `$CLAUDE_PROJECT_DIR/mix.exs` (or
  `apps/*/mix.exs`) must exist.
- Splits the command on `;`, `&&`, `||`, `|`, `&`, newlines, subshells and
  `$(…)`, and checks the command words of each part. Quoted text, `#` comments
  and heredoc bodies are ignored, so `git commit -m "… mix ecto.reset …"` and
  `grep "mix ecto.reset" docs/` pass. Leading `VAR=value`, `env`, `git -C dir`
  and `git -c key=value` are understood; `mix do ecto.drop + ecto.create` is
  checked task by task.
- `MIX_ENV=test` counts when it prefixes the command, was exported earlier in
  the same command line, or is set in Claude Code's environment.
- Known limits: commands inside `bash -c "…"`/`eval` strings, aliases, shell
  functions and `$(…)` inside double quotes are not inspected.

### Opting out

Set `EPG_ALLOW` to a comma-separated list of `force_push`, `ecto_reset`,
`ecto_drop`:

- for a single command: `EPG_ALLOW=force_push git push --force origin release`
- for every session: set it in the environment Claude Code starts with, or in
  the `env` block of `.claude/settings.json`.

The block message tells Claude it may use the prefix only when you asked for
the destructive command explicitly.

## Writing your own

Hooks receive JSON on stdin. Get the file path with:

```bash
FILE=$(jq -r '.tool_input.file_path // empty')
```

(`$CLAUDE_PROJECT_DIR` is the project root. Claude Code does not set a
dedicated file-path environment variable for hooks; read the path from stdin
as shown above.) To give Claude a non-blocking note from a PostToolUse hook,
print JSON built with `jq` and exit 0:

```bash
jq -n --arg c "$TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
```

## Manual install (not using the plugin manager)

Copy the entries from `hooks/hooks.json` into `~/.claude/settings.json` (or a
project's `.claude/settings.json`), replacing `${CLAUDE_PLUGIN_ROOT}` with the
absolute path of your checkout. When merging, **append** to existing event
arrays; don't replace them.

## Testing

```bash
/bin/bash tests/hooks/run_tests.sh         # every hook check, both directions
/bin/bash tests/code_quality/run_tests.sh  # on-demand analyzer (needs elixir)
```

The hook suite has fixtures for every check above, the Bash guard cases in
both directions, changed-lines behaviour for `Edit`, `MultiEdit` and `Write`,
and the SessionStart summary for umbrella, library, lock-only and
upgraded-without-scopes projects.
