#!/bin/bash
# Full Project Code Quality Analysis
# Runs all code quality checks across the entire project.
#
# Usage:
#   run_analysis.sh [directory]   — defaults to current directory

DIR="${1:-.}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EXIT_CODE=0

if [ ! -d "$DIR/lib" ]; then
  echo "No lib/ directory found. Run from an Elixir project root."
  exit 1
fi

echo "Elixir Phoenix Guide — Code Quality Analysis"
echo "============================================="
echo ""

# Run Elixir code analysis
if command -v elixir >/dev/null 2>&1; then
  echo "Analyzing Elixir files..."
  elixir "$SCRIPTS_DIR/code_quality.exs" scan "$DIR/lib"
  if [ $? -ne 0 ]; then
    EXIT_CODE=1
  fi
else
  echo "Elixir not found. Skipping code analysis."
fi

echo ""

# Run template duplication check
echo "Analyzing HEEx templates..."
TEMPLATE_ISSUES=0
TEMPLATE_COUNT=0

while IFS= read -r -d '' file; do
  TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
  bash "$SCRIPTS_DIR/detect_template_duplication.sh" "$file"
  if [ $? -ne 0 ]; then
    TEMPLATE_ISSUES=1
  fi
done < <(find "$DIR/lib" -name "*.heex" -print0 2>/dev/null)

if [ "$TEMPLATE_COUNT" -eq 0 ]; then
  echo "No .heex templates found."
elif [ "$TEMPLATE_ISSUES" -eq 0 ]; then
  echo "No template duplication issues found ($TEMPLATE_COUNT templates checked)"
fi

if [ "$TEMPLATE_ISSUES" -eq 1 ]; then
  EXIT_CODE=1
fi

echo ""
echo "Analysis complete."
exit $EXIT_CODE
