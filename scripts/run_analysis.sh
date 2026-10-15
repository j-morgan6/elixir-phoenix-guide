#!/usr/bin/env bash
# Full project code quality analysis (duplication + branch complexity).
#
# Usage:
#   run_analysis.sh [project_dir]   - defaults to the current directory
#
# Scans <project_dir>/lib, or every apps/*/lib at an umbrella root (all
# apps in one pass, so duplication across apps is found).

DIR="${1:-.}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set --
if [ -d "$DIR/lib" ]; then
  set -- "$DIR/lib"
fi
for d in "$DIR"/apps/*/lib; do
  [ -d "$d" ] && set -- "$@" "$d"
done

if [ $# -eq 0 ]; then
  echo "No lib/ or apps/*/lib directory found. Run from an Elixir project root."
  exit 1
fi

if ! command -v elixir >/dev/null 2>&1; then
  echo "elixir not found. Skipping code analysis."
  exit 1
fi

echo "elixir-phoenix-guide - code quality analysis"
echo "============================================"
echo "Run 'mix compile --warnings-as-errors' and 'mix credo --strict' first;"
echo "they cover unused code and the project's own complexity limits."
echo ""

elixir "$SCRIPTS_DIR/code_quality.exs" scan "$@"
