# shellcheck shell=bash
# Shared helpers for detect_project.sh and hooks/*.sh. Sourced, not executed.
# Must stay compatible with macOS /bin/bash 3.2 and BSD userland.

# epg_hash: read stdin, print a short stable key. Writer (detect_project.sh)
# and reader (check_file.sh) run on the same machine, so whichever tool is
# found first gives matching keys. shasum is missing on slim Debian/Alpine.
epg_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum | cut -c1-12
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum | cut -c1-12
  else
    cksum | awk '{print $1}'
  fi
}

# epg_is_elixir_project DIR: true when DIR has mix.exs or is an umbrella
# with apps/*/mix.exs.
epg_is_elixir_project() {
  local d="$1" f
  [ -f "$d/mix.exs" ] && return 0
  for f in "$d"/apps/*/mix.exs; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# epg_find_project_root: nearest ancestor of $PWD with mix.exs; an umbrella
# child (…/apps/<name>) resolves to the umbrella root. Prints nothing and
# returns 1 when none is found.
epg_find_project_root() {
  local dir="$PWD" parent
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -f "$dir/mix.exs" ]; then
      parent="$(dirname "$dir")"
      if [ "$(basename "$parent")" = "apps" ] && [ -f "$(dirname "$parent")/mix.exs" ]; then
        dir="$(dirname "$parent")"
      fi
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# epg_project_root: CLAUDE_PROJECT_DIR when set (Claude Code always sets it
# for hooks), else the walk-up result, else $PWD.
epg_project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    echo "$CLAUDE_PROJECT_DIR"
  else
    epg_find_project_root || echo "$PWD"
  fi
}

# epg_cache_file ROOT: path of the per-project cache written at SessionStart.
epg_cache_file() {
  local dir key
  dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/elixir-phoenix-guide}/cache"
  key=$(printf '%s' "$1" | epg_hash)
  echo "$dir/$key.json"
}
