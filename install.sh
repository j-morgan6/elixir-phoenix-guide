#!/usr/bin/env bash
# elixir-phoenix-guide — optional extras installer.
# The plugin itself (skills + hooks) installs via Claude Code's plugin manager:
#   /plugin marketplace add j-morgan6/elixir-phoenix-guide
#   /plugin install elixir-phoenix-guide@elixir-phoenix-guide
# This script only: (a) offers the CLAUDE.md template, (b) cleans up legacy
# installs (~/.claude/scripts/elixir-phoenix-guide + old settings hooks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ ! -f "$SCRIPT_DIR/CLAUDE.md.template" ]; then
  echo "Run this from a checkout of elixir-phoenix-guide (CLAUDE.md.template not found)." >&2
  exit 1
fi

echo "elixir-phoenix-guide extras installer"
echo "Skills and hooks ship with the plugin — nothing to copy for those."
echo ""

# --- legacy cleanup ---
LEGACY="$HOME/.claude/scripts/elixir-phoenix-guide"
if [ -d "$LEGACY" ]; then
  echo "Found a legacy (pre-2.4.0) script install at $LEGACY — it is no longer used."
  response=n
  if [ -r /dev/tty ]; then
    printf "Delete it? [y/N] "
    read -r response < /dev/tty || response=n
  fi
  if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
    rm -rf "$LEGACY"
    echo "Removed."
  else
    echo "Left in place. Delete it yourself when ready: rm -rf \"$LEGACY\""
  fi
  echo "NOTE: if you previously merged hooks-settings.json into ~/.claude/settings.json,"
  echo "remove those entries manually — they were inert and are superseded by plugin hooks."
fi

# --- CLAUDE.md template (only when running interactively) ---
if [ -t 0 ] || [ -r /dev/tty ]; then
  TARGET="${CLAUDE_PROJECT_DIR:-$PWD}/CLAUDE.md"
  if [ ! -f "$TARGET" ]; then
    printf "Copy CLAUDE.md.template to %s? [y/N] " "$TARGET"
    read -r response < /dev/tty || response=n
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
      cp "$SCRIPT_DIR/CLAUDE.md.template" "$TARGET"
      echo "Copied. Edit the placeholders (app name, module prefix)."
    fi
  else
    echo "CLAUDE.md already exists at $TARGET — not touching it."
  fi
else
  echo "Non-interactive shell: skipping CLAUDE.md prompt."
  echo "Copy it yourself: cp CLAUDE.md.template <your-project>/CLAUDE.md"
fi

echo "Done."
