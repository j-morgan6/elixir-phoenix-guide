#!/usr/bin/env bash
# Test harness for the plugin hooks. Feeds Claude Code-shaped JSON on stdin
# and asserts exit codes, stderr (blocking tier) and the PostToolUse
# additionalContext JSON (review tier). Hooks run under the same bash as this
# script, so `/bin/bash tests/hooks/run_tests.sh` exercises macOS bash 3.2.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/tests/hooks/fixtures"
SH="${BASH:-bash}"
PASS=0; FAIL=0

# Hermetic env: plugin data dir in a temp dir; no inherited project/opt-outs.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_DATA="$TMP/plugin_data"
unset CLAUDE_PROJECT_DIR EPG_ALLOW MIX_ENV CLAUDE_PLUGIN_ROOT 2>/dev/null || true

ok()   { PASS=$((PASS+1)); }
bad()  { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# run_hook SCRIPT JSON -> OUT, ERR, RC
run_hook() {
  OUT=$(printf '%s' "$2" | "$SH" "$ROOT/scripts/$1" 2>"$TMP/stderr"); RC=$?
  ERR=$(cat "$TMP/stderr")
}

# Blocking tier: exit 2 and the pattern on stderr.
expect_block() { # name script json pattern
  run_hook "$2" "$3"
  [ "$RC" -eq 2 ] || { bad "$1" "exit $RC (want 2) stderr=[$ERR] stdout=[$OUT]"; return; }
  printf '%s' "$ERR" | grep -qF -- "$4" || { bad "$1" "stderr missing '$4': $ERR"; return; }
  ok
}

# Review tier: exit 0, stdout is PostToolUse JSON whose additionalContext
# contains the pattern, nothing on stderr.
expect_review() { # name json pattern
  run_hook hooks/check_file.sh "$2"
  [ "$RC" -eq 0 ] || { bad "$1" "exit $RC (want 0) stderr=[$ERR]"; return; }
  [ -z "$ERR" ] || { bad "$1" "unexpected stderr: $ERR"; return; }
  local ctx
  ctx=$(printf '%s' "$OUT" | jq -er 'select(.hookSpecificOutput.hookEventName == "PostToolUse") | .hookSpecificOutput.additionalContext' 2>/dev/null) ||
    { bad "$1" "stdout is not PostToolUse additionalContext JSON: $OUT"; return; }
  printf '%s' "$ctx" | grep -qF -- "$3" || { bad "$1" "additionalContext missing '$3': $ctx"; return; }
  ok
}

# Silent pass: exit 0, no stdout, no stderr.
expect_clean() { # name script json
  run_hook "$2" "$3"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok
  else
    bad "$1" "exit $RC stdout=[$OUT] stderr=[$ERR] (want silent exit 0)"
  fi
}

# The pattern must appear nowhere in the hook's output.
expect_absent() { # name json pattern
  run_hook hooks/check_file.sh "$2"
  if printf '%s\n%s' "$OUT" "$ERR" | grep -qF -- "$3"; then bad "$1" "unexpected '$3' in output: $OUT $ERR"; return; fi
  ok
}

j() { jq -n --arg f "$1" '{tool_input: {file_path: $f}}'; }
jw() { jq -n --arg f "$1" '{tool_name: "Write", tool_input: {file_path: $f, content: ""}}'; }
je() { jq -n --arg f "$1" --arg s "$2" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "x", new_string: $s, replace_all: false}}'; }
b() { printf '%s' "$1" | jq -Rs '{tool_name: "Bash", tool_input: {command: .}}'; }

CF=hooks/check_file.sh
BG=hooks/bash_guard.sh

# ---------------------------------------------------------------- packaging
if jq -e '.hooks.PostToolUse[0].matcher == "Write|Edit|MultiEdit"' "$ROOT/hooks/hooks.json" >/dev/null; then ok
else bad hooks_json_matcher "PostToolUse matcher must be Write|Edit|MultiEdit"; fi

# ---------------------------------------------------------------- fail-open
expect_clean empty_stdin_bash   $BG ''
expect_clean garbage_stdin_bash $BG 'not json'
expect_clean empty_stdin_file   $CF ''
expect_clean garbage_stdin_file $CF 'not json'
expect_clean missing_file       $CF "$(j "$FIX/does_not_exist.ex")"

# ================================================================ bash_guard
PROJ="$TMP/elixir_proj"; mkdir -p "$PROJ"; : > "$PROJ/mix.exs"
UMB="$TMP/umbrella_proj"; mkdir -p "$UMB/apps/web"; : > "$UMB/apps/web/mix.exs"
export CLAUDE_PROJECT_DIR="$PROJ"

# 2.2 "blocked but harmless" -> now allowed
expect_clean test_env_reset_allowed    $BG "$(b 'MIX_ENV=test mix ecto.reset')"
expect_clean commit_msg_mentions_reset $BG "$(b 'git commit -m "docs: never run mix ecto.reset in prod"')"
expect_clean grep_for_reset            $BG "$(b 'grep -rn "mix ecto.reset" docs/')"
# 2.2 "allowed but dangerous" -> now blocked
expect_block ecto_drop_blocked         $BG "$(b 'mix ecto.drop')"                     'ecto.drop'
expect_block plus_refspec_blocked      $BG "$(b 'git push origin +main')"             'force-with-lease'
expect_block combined_uf_blocked       $BG "$(b 'git push -uf origin main')"          'force-with-lease'
expect_block combined_fu_blocked       $BG "$(b 'git push -fu origin main')"          'force-with-lease'
expect_block git_C_push_force_blocked  $BG "$(b 'git -C dir push --force')"           'force-with-lease'
expect_block lease_then_force_blocked  $BG "$(b 'git push --force-with-lease x && git push --force y')" 'force-with-lease'
# still blocked / still allowed
expect_block ecto_reset_blocked        $BG "$(b 'mix ecto.reset')"                    'ecto.rollback'
expect_block force_push_blocked        $BG "$(b 'git push --force origin main')"      'force-with-lease'
expect_block force_after_args          $BG "$(b 'git push origin main --force')"      'force-with-lease'
expect_block short_f_blocked           $BG "$(b 'git push -f')"                       'force-with-lease'
expect_block git_c_config_push_f       $BG "$(b 'git -c push.default=current push -f')" 'force-with-lease'
expect_block force_and_lease_blocked   $BG "$(b 'git push --force-with-lease --force origin main')" 'force-with-lease'
expect_block mix_do_drop_blocked       $BG "$(b 'mix do ecto.drop + ecto.create')"    'ecto.drop'
expect_block subshell_drop_blocked     $BG "$(b '(cd apps/core; mix ecto.drop)')"     'ecto.drop'
expect_block pipe_reset_blocked        $BG "$(b 'yes 2>&1 | mix ecto.reset')"         'ecto.reset'
expect_block dev_env_reset_blocked     $BG "$(b 'MIX_ENV=dev mix ecto.reset')"        'dev database'
expect_block newline_segment_blocked   $BG "$(b "$(printf 'echo start\nmix ecto.reset')")" 'ecto.reset'
expect_clean force_lease_allowed       $BG "$(b 'git push --force-with-lease origin main')"
expect_clean force_if_includes_allowed $BG "$(b 'git push --force-with-lease --force-if-includes origin main')"
expect_clean plain_push_allowed        $BG "$(b 'git push origin main')"
expect_clean push_option_allowed       $BG "$(b 'git push -o ci.skip origin main')"
expect_clean prod_env_allowed          $BG "$(b 'MIX_ENV=prod mix assets.deploy')"
expect_clean exported_test_env         $BG "$(b 'export MIX_ENV=test; mix ecto.reset')"
expect_clean env_cmd_test_env          $BG "$(b 'env MIX_ENV=test mix ecto.drop')"
expect_clean quoted_test_env           $BG "$(b "cd apps/core && MIX_ENV='test' mix ecto.drop")"
expect_clean mix_help_reset            $BG "$(b 'mix help ecto.reset')"
expect_clean shell_comment             $BG "$(b 'mix test # then maybe mix ecto.reset')"
expect_clean heredoc_body              $BG "$(b "$(printf 'cat <<EOF > notes.md\nmix ecto.reset\nEOF')")"
# shellcheck disable=SC2016 # literal $(cat <<EOF) is the input under test
expect_clean heredoc_commit_msg        $BG "$(b "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: stop calling mix ecto.reset\n\nalso no git push --force\nEOF\n)"')")"
expect_clean echo_force_text           $BG "$(b 'echo "git push --force is blocked"')"
# opt-out: command prefix, export, hook environment
expect_clean optout_prefix_force       $BG "$(b 'EPG_ALLOW=force_push git push --force origin release')"
expect_clean optout_export_reset       $BG "$(b 'export EPG_ALLOW=ecto_reset && mix ecto.reset')"
expect_block optout_wrong_token        $BG "$(b 'EPG_ALLOW=ecto_reset git push -f')" 'force-with-lease'
run_hook $BG "$(b 'mix ecto.drop')"
if [ "$RC" -eq 2 ]; then ok; else bad optout_env_baseline "exit $RC"; fi
OUT=$(b 'mix ecto.drop' | EPG_ALLOW=ecto_drop "$SH" "$ROOT/scripts/$BG" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad optout_hook_env "exit $RC $OUT"; fi
OUT=$(b 'git push -f' | EPG_ALLOW=ecto_reset,force_push "$SH" "$ROOT/scripts/$BG" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad optout_hook_env_list "exit $RC $OUT"; fi
# Elixir projects only (umbrella root counts)
export CLAUDE_PROJECT_DIR="$TMP"
expect_clean non_elixir_project_skip   $BG "$(b 'git push --force origin main')"
export CLAUDE_PROJECT_DIR="$UMB"
expect_block umbrella_project_guarded  $BG "$(b 'mix ecto.reset')" 'ecto.reset'
unset CLAUDE_PROJECT_DIR

# ================================================================ check_file
# --- blocking tier (exit 2) ---
expect_block sql_adapter_interp   $CF "$(j "$FIX/bad_sql_adapter.ex")"        'SQL injection'
expect_block repo_query_interp    $CF "$(j "$FIX/bad_repo_query.ex")"         'SQL injection'
expect_block repo_query_heredoc   $CF "$(j "$FIX/bad_repo_query_heredoc.ex")" 'line 7'
expect_block fragment_interp      $CF "$(j "$FIX/bad_fragment.ex")"           'fragment'
expect_block redirect_external    $CF "$(j "$FIX/bad_redirect_external.ex")"  'open redirect'
expect_block redirect_external_lv $CF "$(j "$FIX/bad_redirect_external_live.ex")" 'open redirect'
expect_block form_for_removed     $CF "$(j "$FIX/bad_form_for.ex")"           'form_for'
expect_block live_redirect_dep    $CF "$(j "$FIX/bad_live_redirect.ex")"      'live_redirect'
expect_block live_patch_heex      $CF "$(j "$FIX/bad_live_patch.heex")"       'live_patch'
expect_block mixed_tiers          $CF "$(j "$FIX/bad_mixed.ex")"              'Also review'
expect_block mixed_tiers_has_both $CF "$(j "$FIX/bad_mixed.ex")"              'String.to_atom'
expect_clean param_query_ok       $CF "$(j "$FIX/good_repo_query.ex")"
expect_clean redirect_to_params_ok $CF "$(j "$FIX/good_redirect_to.ex")"
expect_clean simple_form_for_ok   $CF "$(j "$FIX/good_simple_form_for.ex")"

# --- review tier (additionalContext, exit 0) ---
expect_review to_atom             "$(j "$FIX/bad_to_atom.ex")"           'String.to_atom'
expect_review raw_heex            "$(j "$FIX/bad_raw.heex")"             'raw/1'
expect_review phoenix_html_raw    "$(j "$FIX/bad_phoenix_html_raw.ex")"  'raw/1'
expect_review logger_password     "$(j "$FIX/bad_logger.ex")"            'Logger'
expect_review logger_warning      "$(j "$FIX/bad_logger_warning.ex")"    'Logger'
expect_review io_inspect          "$(j "$FIX/bad_inspect.ex")"           'IO.inspect'
expect_review dbg_call            "$(j "$FIX/bad_dbg.ex")"               'dbg'
expect_review timing_compare      "$(j "$FIX/bad_timing.ex")"            'secure_compare'
expect_review impl_missing        "$(j "$FIX/bad_impl.ex")"              '@impl'
expect_review impl_second_callback "$(j "$FIX/bad_impl_second_callback.ex")" 'line 7'
expect_review migration_on_delete "$(j "$FIX/migrations/20260101000000_bad_migration.exs")" 'on_delete'
expect_review migration_noindex   "$(j "$FIX/migrations/20260102000000_bad_migration_noindex.exs")" 'no index'
expect_review migration_two_refs  "$(j "$FIX/migrations/20260103000000_two_refs_one_index.exs")" 'no index on that table in this migration - add create index(:table, [:column]) (Postgres does not index foreign keys automatically). (line 7)'
expect_clean  logger_no_secret    $CF "$(j "$FIX/good_logger.ex")"
expect_clean  nil_check_ok        $CF "$(j "$FIX/good_nil_check.ex")"
expect_clean  impl_ok             $CF "$(j "$FIX/good_impl.ex")"
expect_clean  impl_multiclause_ok $CF "$(j "$FIX/good_impl_multiclause.ex")"
expect_clean  plug_init_ok        $CF "$(j "$FIX/good_plug.ex")"
expect_clean  migration_good      $CF "$(j "$FIX/migrations/20260104000000_good.exs")"
expect_clean  clean_file          $CF "$(j "$FIX/good_clean.ex")"

# --- false positives and exclusions ---
expect_clean comments_and_docs    $CF "$(j "$FIX/good_comments.ex")"
expect_clean heex_comments        $CF "$(j "$FIX/good_comments.heex")"
expect_clean deps_excluded        $CF "$(j "$FIX/deps/some_dep/lib/bad.ex")"
expect_clean mix_task_inspect_ok  $CF "$(j "$FIX/lib/mix/tasks/report.ex")"
expect_clean test_file_skipped    $CF "$(j "$FIX/skip_test.exs")"
expect_clean form_for_test_skipped $CF "$(j "$FIX/form_for_test.exs")"
expect_clean non_elixir_skipped   $CF "$(j "$FIX/readme.md")"

# --- changed lines only: Edit / MultiEdit ---
EF="$TMP/edit_target.ex"
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(x), do: String.to_atom(x)

  def added(x) do
    x + 1
  end
end
EOF
expect_clean edit_clean_new_string $CF "$(je "$EF" "$(printf '  def added(x) do\n    x + 1\n  end')")"
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(x), do: String.to_atom(x)

  def added(x) do
    IO.inspect(x)
  end
end
EOF
expect_review edit_bad_new_string "$(je "$EF" "$(printf '  def added(x) do\n    IO.inspect(x)\n  end')")" 'line 5'
expect_absent edit_ignores_old_line "$(je "$EF" "$(printf '  def added(x) do\n    IO.inspect(x)\n  end')")" 'String.to_atom'
# formatter changed indentation after the edit: falls back to trimmed lines
expect_review edit_reindented     "$(je "$EF" "$(printf 'def added(x) do\nIO.inspect(x)\nend')")" 'line 5'
expect_clean  edit_deletion_only  $CF "$(je "$EF" "")"
# replace_all: every occurrence counts as changed
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def a(x), do: dbg(x)
  def b(x), do: x
  def c(x), do: dbg(x)
end
EOF
expect_review edit_replace_all    "$(jq -n --arg f "$EF" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "x", new_string: "dbg(x)", replace_all: true}}')" 'lines 2, 4'
expect_review multiedit_union     "$(jq -n --arg f "$EF" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "def b(x), do: x"}, {old_string: "b", new_string: "def c(x), do: dbg(x)"}]}}')" 'line 4'
expect_absent multiedit_skips_unchanged "$(jq -n --arg f "$EF" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "def b(x), do: x"}, {old_string: "b", new_string: "def c(x), do: dbg(x)"}]}}')" 'line 2'
# @impl evaluated with whole-file context: new clause under an @impl'd one
cat > "$EF" <<'EOF'
defmodule EditLive do
  use Phoenix.LiveView

  @impl true
  def handle_event("a", _p, s), do: {:noreply, s}

  def handle_event("b", _p, s), do: {:noreply, s}
end
EOF
expect_clean edit_new_clause_no_impl $CF "$(je "$EF" '  def handle_event("b", _p, s), do: {:noreply, s}')"

# --- changed lines only: Write in a git repo ---
REPO="$TMP/repo"; mkdir -p "$REPO/lib"
( cd "$REPO" && git init -q && printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\nend\n' > lib/w.ex &&
  git add lib/w.ex && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\n  def clean(x), do: x\nend\n' > "$REPO/lib/w.ex"
expect_clean write_clean_line_ok $CF "$(jw "$REPO/lib/w.ex")"
printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\n  def clean(x), do: x\n  def debug(x), do: IO.inspect(x)\nend\n' > "$REPO/lib/w.ex"
expect_review write_bad_line     "$(jw "$REPO/lib/w.ex")" 'line 4'
expect_absent write_ignores_old  "$(jw "$REPO/lib/w.ex")" 'String.to_atom'
printf 'defmodule N do\n  def n(x), do: String.to_atom(x)\nend\n' > "$REPO/lib/new.ex"
expect_review write_untracked_whole_file "$(jw "$REPO/lib/new.ex")" 'String.to_atom'
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
printf 'defmodule N do\n  def n(x), do: String.to_atom(x)\nend\n' > "$NOGIT/n.ex"
expect_review write_outside_git  "$(jw "$NOGIT/n.ex")" 'String.to_atom'

# --- @current_user only when the project uses scopes ---
# shellcheck source=SCRIPTDIR/../../scripts/lib/common.sh disable=SC1091
. "$ROOT/scripts/lib/common.sh"
export CLAUDE_PROJECT_DIR="$TMP/proj"; mkdir -p "$CLAUDE_PROJECT_DIR"
expect_clean scope_no_cache_ok $CF "$(j "$FIX/bad_current_user.ex")"
SCACHE=$(epg_cache_file "$CLAUDE_PROJECT_DIR"); mkdir -p "$(dirname "$SCACHE")"
printf '{\n  "phoenix_has_scope": true\n}\n' > "$SCACHE"
expect_review scope_current_user "$(j "$FIX/bad_current_user.ex")" 'current_scope'
printf '{\n  "phoenix_has_scope": false\n}\n' > "$SCACHE"
expect_clean scope_false_ok $CF "$(j "$FIX/bad_current_user.ex")"
rm -f "$SCACHE"; unset CLAUDE_PROJECT_DIR

# ============================================================ detect_project
DP="$ROOT/scripts/detect_project.sh"
VER=$(tr -d '[:space:]' < "$ROOT/VERSION")
dp() { ( cd "$1" && CLAUDE_PROJECT_DIR="$1" "$SH" "$DP" 2>&1 ); }
expect_text() { # name text pattern
  if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1" "missing '$3' in: $2"; fi
}
expect_no_text() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "unexpected '$3' in: $2"; else ok; fi
}
cache_scope() { grep -o '"phoenix_has_scope": [a-z]*' "$(epg_cache_file "$1")" 2>/dev/null | sed 's/.*: //'; }
LOCK_LINE() { printf '  "%s": {:hex, :%s, "%s", "abc", [:mix], [], "hexpm", "def"},\n' "$1" "$1" "$2"; }

# Phoenix 1.8 app with scopes, requirement differs from lock
A="$TMP/dp_app"; mkdir -p "$A/lib/app/accounts" "$A/lib/app_web"
cat > "$A/mix.exs" <<'EOF'
defmodule App.MixProject do
  use Mix.Project
  def project, do: [app: :app, deps: deps()]
  defp deps do
    [{:phoenix, "~> 1.8.1"}, {:phoenix_live_view, "~> 1.1"}, {:ecto_sql, "~> 3.13"},
     {:postgrex, ">= 0.0.0"}, {:oban_web, "~> 2.11"}]
  end
end
EOF
{ printf '%%{\n'; LOCK_LINE phoenix 1.8.15; LOCK_LINE phoenix_live_view 1.2.12; LOCK_LINE ecto 3.14.2; printf '}\n'; } > "$A/mix.lock"
printf 'defmodule App.Accounts.Scope do\n  defstruct user: nil\nend\n' > "$A/lib/app/accounts/scope.ex"
OUT=$(dp "$A")
expect_text dp_version_line     "$OUT" "elixir-phoenix-guide $VER:"
expect_text dp_locked_and_req   "$OUT" 'Phoenix 1.8.15 (mix.exs ~> 1.8.1)'
expect_text dp_liveview         "$OUT" 'LiveView 1.2.12'
expect_text dp_scope            "$OUT" 'scopes in use'
expect_text dp_ecto             "$OUT" 'Ecto 3.14.2 (postgres)'
expect_no_text dp_oban_web_not_oban "$OUT" 'Oban'
if [ "$(cache_scope "$A")" = true ]; then ok; else bad dp_cache_scope_true "cache: $(cat "$(epg_cache_file "$A")" 2>/dev/null)"; fi
if grep -qE 'has_liveview|has_ecto|ecto_adapter|has_oban|app_name' "$(epg_cache_file "$A")"; then bad dp_cache_unread_keys "unread keys still cached"; else ok; fi

# upgraded to 1.8 without adopting scopes
U="$TMP/dp_upgraded"; mkdir -p "$U/lib/app_web"
printf 'defmodule U.MixProject do\n  use Mix.Project\n  def project, do: [app: :u, deps: [{:phoenix, "~> 1.7"}]]\nend\n' > "$U/mix.exs"
{ printf '%%{\n'; LOCK_LINE phoenix 1.8.15; printf '}\n'; } > "$U/mix.lock"
printf 'defmodule UWeb.UserAuth do\n  def fetch_current_user(conn, _), do: assign(conn, :current_user, nil)\nend\n' > "$U/lib/app_web/user_auth.ex"
OUT=$(dp "$U")
expect_text dp_upgraded_version "$OUT" 'Phoenix 1.8.15 (mix.exs ~> 1.7)'
expect_text dp_upgraded_noscope "$OUT" 'no scopes'
if [ "$(cache_scope "$U")" = false ]; then ok; else bad dp_upgraded_cache "scope should be false"; fi
OUT=$(printf '%s' "$(j "$FIX/bad_current_user.ex")" | CLAUDE_PROJECT_DIR="$U" "$SH" "$ROOT/scripts/$CF" 2>&1)
if [ -z "$OUT" ]; then ok; else bad dp_upgraded_no_current_user_flag "$OUT"; fi

# current_scope in user_auth.ex without a Scope module still counts
printf 'defmodule UWeb.UserAuth do\n  def on_mount(_, _, _, s), do: {:cont, assign(s, :current_scope, nil)}\nend\n' > "$U/lib/app_web/user_auth.ex"
OUT=$(dp "$U")
expect_text dp_user_auth_scope "$OUT" 'scopes in use'

# lock-only: requirement not a literal string
L="$TMP/dp_lockonly"; mkdir -p "$L"
printf 'defmodule L.MixProject do\n  use Mix.Project\n  @phx "~> 1.8.0"\n  def project, do: [app: :l, deps: [{:phoenix, @phx}, {:oban, "~> 2.20"}]]\nend\n' > "$L/mix.exs"
{ printf '%%{\n'; LOCK_LINE phoenix 1.8.15; LOCK_LINE oban 2.24.2; printf '}\n'; } > "$L/mix.lock"
OUT=$(dp "$L")
expect_text dp_lockonly_version "$OUT" 'Phoenix 1.8.15'
expect_no_text dp_lockonly_noreq "$OUT" 'mix.exs'
expect_text dp_oban_exact       "$OUT" 'Oban 2.24.2'

# requirement only (no mix.lock yet)
R="$TMP/dp_reqonly"; mkdir -p "$R"
printf 'defmodule R.MixProject do\n  use Mix.Project\n  def project, do: [app: :r, deps: [{:phoenix, "~> 1.8.1"}]]\nend\n' > "$R/mix.exs"
OUT=$(dp "$R")
expect_text dp_reqonly "$OUT" 'Phoenix ~> 1.8.1 (not locked'

# library (no Phoenix)
B="$TMP/dp_lib"; mkdir -p "$B/lib"
printf 'defmodule B.MixProject do\n  use Mix.Project\n  def project, do: [app: :b, deps: [{:jason, "~> 1.4"}]]\nend\n' > "$B/mix.exs"
OUT=$(dp "$B")
expect_text dp_library        "$OUT" 'Elixir project (no Phoenix)'
expect_no_text dp_library_no_unknown "$OUT" 'unknown'

# umbrella: LiveView declared only in apps/web/mix.exs
M="$TMP/dp_umbrella"; mkdir -p "$M/apps/web/lib/web" "$M/apps/core/lib/core/accounts"
printf 'defmodule M.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: "apps", deps: []]\nend\n' > "$M/mix.exs"
printf 'defmodule Web.MixProject do\n  use Mix.Project\n  def project, do: [app: :web, deps: [{:phoenix, "~> 1.8.0"}, {:phoenix_live_view, "~> 1.1"}, {:core, in_umbrella: true}]]\nend\n' > "$M/apps/web/mix.exs"
printf 'defmodule Core.MixProject do\n  use Mix.Project\n  def project, do: [app: :core, deps: [{:ecto_sql, "~> 3.13"}, {:postgrex, ">= 0.0.0"}]]\nend\n' > "$M/apps/core/mix.exs"
{ printf '%%{\n'; LOCK_LINE phoenix 1.8.15; LOCK_LINE phoenix_live_view 1.2.12; LOCK_LINE ecto 3.14.2; printf '}\n'; } > "$M/mix.lock"
printf 'defmodule Core.Accounts.Scope do\n  defstruct user: nil\nend\n' > "$M/apps/core/lib/core/accounts/scope.ex"
OUT=$(dp "$M")
expect_text dp_umbrella_apps "$OUT" 'umbrella (apps: core, web)'
expect_text dp_umbrella_lv   "$OUT" 'LiveView 1.2.12'
expect_text dp_umbrella_scope "$OUT" 'scopes in use'
expect_text dp_umbrella_ecto "$OUT" 'Ecto 3.14.2 (postgres)'

# not an Elixir project: silent
N="$TMP/dp_none"; mkdir -p "$N"
OUT=$(dp "$N")
if [ -z "$OUT" ]; then ok; else bad dp_non_elixir_silent "$OUT"; fi

# jq missing: warn (Elixir projects only)
NOJQ="$TMP/nojq_bin"; mkdir -p "$NOJQ"
for t in dirname basename tr grep sed head find mkdir date cat cut awk shasum sha1sum cksum perl; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOJQ/$t"
done
OUT=$( cd "$B" && PATH="$NOJQ" CLAUDE_PROJECT_DIR="$B" "$SH" "$DP" 2>&1 )
expect_text dp_jq_missing "$OUT" 'jq not found'
OUT=$( cd "$A" && CLAUDE_PROJECT_DIR="$A" "$SH" "$DP" 2>&1 )
expect_no_text dp_jq_present "$OUT" 'jq not found'
OUT=$( cd "$N" && PATH="$NOJQ" CLAUDE_PROJECT_DIR="$N" "$SH" "$DP" 2>&1 )
if [ -z "$OUT" ]; then ok; else bad dp_jq_missing_non_elixir_silent "$OUT"; fi

# writer/reader parity: CLAUDE_PROJECT_DIR unset, both walk up from a subdir
# (an umbrella child resolves to the umbrella root).
PROJ2="$TMP/proj2"; mkdir -p "$PROJ2/lib/app"
printf 'defmodule P.MixProject do\n  use Mix.Project\n  def project, do: [app: :p, deps: [{:phoenix, "~> 1.8.0"}]]\nend\n' > "$PROJ2/mix.exs"
printf 'defmodule P.Scope do\nend\n' > "$PROJ2/lib/app/scope.ex"
( cd "$PROJ2/lib" && "$SH" "$DP" >/dev/null 2>&1 )
OUT=$( cd "$PROJ2/lib" && printf '%s' "$(j "$FIX/bad_current_user.ex")" | "$SH" "$ROOT/scripts/$CF" 2>/dev/null )
if printf '%s' "$OUT" | grep -qF 'current_scope'; then ok; else bad walkup_cache_parity "no current_scope finding: $OUT"; fi
( cd "$M/apps/web/lib" && "$SH" "$DP" >/dev/null 2>&1 )
if [ "$(cd "$M/apps/web/lib" && epg_project_root)" = "$M" ]; then ok; else bad umbrella_walkup_root "$(cd "$M/apps/web/lib" && epg_project_root)"; fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
