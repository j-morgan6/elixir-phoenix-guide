#!/bin/bash
# Template Duplication Detector
# Finds duplicated HEEx markup across templates in the same directory.
# Usage: detect_template_duplication.sh <file_path>

FILE="$1"
THRESHOLD=20  # minimum identical lines to report

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  exit 0
fi

# Only process .heex files
case "$FILE" in
  *.heex) ;;
  *) exit 0 ;;
esac

DIR=$(dirname "$FILE")
BASENAME=$(basename "$FILE")
FOUND=0

for SIBLING in "$DIR"/*.heex; do
  [ "$SIBLING" = "$FILE" ] && continue
  [ ! -f "$SIBLING" ] && continue

  SIB_BASENAME=$(basename "$SIBLING")

  # Count identical lines using comm (works on both macOS and Linux)
  # Sort both files, find common lines, count them
  COMMON_LINES=$(comm -12 <(sort "$FILE") <(sort "$SIBLING") 2>/dev/null | grep -cv '^\s*$')
  TOTAL_LINES=$(grep -cv '^\s*$' "$FILE" 2>/dev/null || echo 0)

  if [ "$TOTAL_LINES" -eq 0 ]; then
    continue
  fi

  if [ "$COMMON_LINES" -ge "$THRESHOLD" ]; then
    PCT=$((COMMON_LINES * 100 / TOTAL_LINES))
    if [ "$PCT" -ge 40 ]; then
      if [ "$FOUND" -eq 0 ]; then
        echo "Template Duplication Detected"
        FOUND=1
      fi
      echo "   $COMMON_LINES identical lines ($PCT%) between:"
      echo "     $BASENAME"
      echo "     $SIB_BASENAME"
      echo "   Suggestion: Extract shared markup to a function component"
      echo ""
    fi
  fi
done

if [ "$FOUND" -eq 1 ]; then
  exit 1
fi

exit 0
