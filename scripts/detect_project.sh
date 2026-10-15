#!/usr/bin/env bash
# SessionStart hook for the elixir-phoenix-guide plugin.
# Prints a one-line project summary (stdout becomes session context) and
# caches the one fact the PostToolUse check needs (phoenix_has_scope) in
# ${CLAUDE_PLUGIN_DATA:-~/.claude/elixir-phoenix-guide}/cache/<key>.json.
# Silent outside Elixir projects. No jq dependency.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

ROOT="${CLAUDE_PROJECT_DIR:-$(epg_find_project_root 2>/dev/null || true)}"
[ -n "$ROOT" ] || exit 0
epg_is_elixir_project "$ROOT" || exit 0

PLUGIN_VERSION=""
for v in "${CLAUDE_PLUGIN_ROOT:-}/VERSION" "$SCRIPT_DIR/../VERSION"; do
  if [ -f "$v" ]; then
    PLUGIN_VERSION=$(tr -cd '0-9A-Za-z.+-' < "$v")
    break
  fi
done

# --- inputs: root mix.exs plus umbrella apps -------------------------------
MIX_FILES=""
[ -f "$ROOT/mix.exs" ] && MIX_FILES="$ROOT/mix.exs"
APPS=""
for f in "$ROOT"/apps/*/mix.exs; do
  [ -f "$f" ] || continue
  MIX_FILES="$MIX_FILES
$f"
  APPS="${APPS:+$APPS, }$(basename "$(dirname "$f")")"
done
LIB_DIRS=""
for d in "$ROOT/lib" "$ROOT"/apps/*/lib; do
  [ -d "$d" ] && LIB_DIRS="$LIB_DIRS
$d"
done

LOCK="$ROOT/mix.lock"
if [ ! -f "$LOCK" ] && [ "$(basename "$(dirname "$ROOT")")" = apps ] && [ -f "$ROOT/../../mix.lock" ]; then
  LOCK="$ROOT/../../mix.lock"   # session opened inside an umbrella child
fi

mix_grep() { # ERE over all mix.exs files
  local f
  printf '%s\n' "$MIX_FILES" | while IFS= read -r f; do
    [ -n "$f" ] && grep -hE "$1" "$f" 2>/dev/null
  done
}

# exact dep name, so :oban does not match :oban_web / :oban_met
has_dep() { mix_grep "\{[[:space:]]*:$1[[:space:]]*[,}]" | grep -q .; }

requirement() {
  mix_grep "\{[[:space:]]*:$1[[:space:]]*,[[:space:]]*\"[^\"]+\"" |
    sed -E "s/.*\{[[:space:]]*:$1[[:space:]]*,[[:space:]]*\"([^\"]+)\".*/\1/" | head -n 1
}

locked() {
  [ -f "$LOCK" ] || return 0
  local line
  line=$(grep -E "^[[:space:]]*\"$1\":" "$LOCK" 2>/dev/null | head -n 1)
  [ -n "$line" ] || return 0
  case "$line" in
    *"{:hex, :$1, \""*) printf '%s\n' "$line" | sed -E "s/.*\{:hex, :$1, \"([^\"]+)\".*/\1/" ;;
    *) echo "git/path" ;;
  esac
}

# "1.8.15 (mix.exs ~> 1.8.1)", "1.8.15", "~> 1.8.1 (not locked)", ""
describe_version() {
  local req lock
  req=$(requirement "$1"); lock=$(locked "$1")
  if [ -n "$lock" ] && [ -n "$req" ]; then echo "$lock (mix.exs $req)"
  elif [ -n "$lock" ]; then echo "$lock"
  elif [ -n "$req" ]; then echo "$req (not locked; run mix deps.get)"
  fi
}

PARTS=""
add_part() { PARTS="${PARTS:+$PARTS, }$1"; }

HAS_PHOENIX=false
if has_dep phoenix || [ -n "$(locked phoenix)" ]; then HAS_PHOENIX=true; fi

HAS_SCOPE=false
if [ "$HAS_PHOENIX" = true ]; then
  add_part "Phoenix $(describe_version phoenix)"
  if has_dep phoenix_live_view; then add_part "LiveView $(describe_version phoenix_live_view)"; fi

  # Scopes are a code fact, not a version fact: apps upgraded to 1.8
  # without adopting scopes still use @current_user.
  SCOPE_MOD=""; AUTH_SCOPE=""
  printf '%s\n' "$LIB_DIRS" | while IFS= read -r d; do
    [ -n "$d" ] && grep -rlsE --include='*.ex' 'defmodule[[:space:]]+[A-Za-z0-9_.]+\.Scope([[:space:],]|$)' "$d"
  done | grep -q . && SCOPE_MOD=1
  printf '%s\n' "$LIB_DIRS" | while IFS= read -r d; do
    [ -n "$d" ] && find "$d" -name '*user_auth.ex' -exec grep -l 'current_scope' {} + 2>/dev/null
  done | grep -q . && AUTH_SCOPE=1
  if [ -n "$SCOPE_MOD" ] || [ -n "$AUTH_SCOPE" ]; then
    HAS_SCOPE=true
    add_part "scopes in use (@current_scope)"
  else
    add_part "no scopes (no Scope module; follow the project's existing @current_user pattern)"
  fi
fi

if has_dep ecto_sql || has_dep ecto; then
  ADAPTER=""
  if has_dep postgrex; then ADAPTER=postgres
  elif has_dep ecto_sqlite3; then ADAPTER=sqlite
  elif has_dep myxql; then ADAPTER=mysql
  elif has_dep tds; then ADAPTER=mssql
  fi
  add_part "Ecto $(locked ecto)${ADAPTER:+ ($ADAPTER)}"
fi
if has_dep oban; then add_part "Oban $(locked oban)"; fi

# --- cache (only keys a hook reads, plus provenance) -------------------------
CACHE_FILE=$(epg_cache_file "$ROOT")
if mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null; then
  cat > "$CACHE_FILE" 2>/dev/null <<EOF
{
  "plugin_version": "${PLUGIN_VERSION:-unknown}",
  "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phoenix_has_scope": $HAS_SCOPE
}
EOF
fi

# --- summary for Claude's context ------------------------------------------
KIND=""
[ "$HAS_PHOENIX" = true ] || KIND="Elixir project (no Phoenix)"
[ -n "$APPS" ] && KIND="${KIND:+$KIND, }umbrella (apps: $APPS)"
PARTS=$(printf '%s' "$PARTS" | sed -E 's/  +/ /g; s/ ,/,/g; s/ +$//')
SUMMARY="$KIND"
[ -n "$PARTS" ] && SUMMARY="${SUMMARY:+$SUMMARY; }$PARTS"
echo "elixir-phoenix-guide${PLUGIN_VERSION:+ $PLUGIN_VERSION}: $SUMMARY. Invoke the plugin's skills before writing Elixir code."
if ! command -v jq >/dev/null 2>&1; then
  echo "elixir-phoenix-guide: jq not found — file and Bash checks are disabled. Install jq to enable them."
fi
exit 0
