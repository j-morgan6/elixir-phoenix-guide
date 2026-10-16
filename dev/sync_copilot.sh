#!/usr/bin/env bash
# Regenerates the Copilot port from the canonical skills/scripts.
# Instruction files keep their existing applyTo frontmatter; bodies are
# replaced with the corresponding SKILL.md body (first frontmatter block stripped).
set -euo pipefail
TMPDIR_SYNC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SYNC"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/copilot/.github/instructions"

# extract_frontmatter FILE -> prints the first ---...--- block inclusive
extract_frontmatter() {
  awk 'NR==1 && /^---$/ {infm=1; print; next}
       infm && /^---$/ {print; exit}
       infm {print}' "$1"
}

# extract_body FILE -> prints everything AFTER the first frontmatter block
extract_body() {
  awk 'NR==1 && /^---$/ {infm=1; next}
       infm && /^---$/ {infm=0; body=1; next}
       infm {next}
       body {print}' "$1"
}

# Supporting files (skills/<skill>/<file>.md) become AGENTS.md sections in the
# Copilot port, since Copilot instructions can't link to sibling files.
# Format: skill/file|Section title
SUPPORTING="
ecto-essentials/reference.md|Ecto Reference
elixir-essentials/project-structure.md|Phoenix Project Structure
phoenix-liveview-essentials/checklist.md|LiveView Checklist
phoenix-liveview-essentials/js-interop.md|LiveView JS Interop
testing-essentials/reference.md|Testing Reference
ecto-migrations-safety/reference.md|Ecto Migrations Reference
ecto-queries-performance/reference.md|Ecto Queries Reference
http-clients-req/reference.md|HTTP Clients Reference
"

# Every supporting file must be mapped above, or its links would dangle in
# the Copilot port.
for f in "$ROOT"/skills/*/*.md; do
  case "$f" in */SKILL.md) continue ;; esac
  rel="${f#"$ROOT/skills/"}"
  if ! printf '%s\n' "$SUPPORTING" | grep -q "^$rel|"; then
    echo "ERROR: $rel is not mapped in SUPPORTING (dev/sync_copilot.sh)" >&2
    exit 1
  fi
done

# rewrite_links SKILL -> rewrites a skill body (stdin) for Copilot:
#   [text](file.md)  -> text (see "<Section>" in AGENTS.md)
#   ${CLAUDE_SKILL_DIR}/../../scripts/ -> scripts/
rewrite_links() {
  local skill="$1" sed_args=() entry rel title
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel="${entry%%|*}"; title="${entry#*|}"
    case "$rel" in "$skill"/*) ;; *) continue ;; esac
    sed_args+=(-e "s#\[\([^]]*\)\](${rel#*/})#\1 (see \"${title}\" in AGENTS.md)#g")
  done <<< "$SUPPORTING"
  # shellcheck disable=SC2016 # literal ${CLAUDE_SKILL_DIR} in the pattern
  sed_args+=(-e 's#\${CLAUDE_SKILL_DIR}/\.\./\.\./scripts/#scripts/#g')
  # shellcheck disable=SC2016 # literal ${CLAUDE_SKILL_DIR} in the pattern
  sed_args+=(-e 's# `\${CLAUDE_SKILL_DIR}` is this skill.s own directory[^.]*\.##')
  sed "${sed_args[@]}"
}

for skill_dir in "$ROOT"/skills/*/; do
  name=$(basename "$skill_dir")
  src="$skill_dir/SKILL.md"
  dst="$DEST/$name.instructions.md"
  if [ ! -f "$dst" ]; then
    echo "SKIP $name (no instruction file — create it manually with an applyTo header)" >&2
    continue
  fi
  { extract_frontmatter "$dst"; extract_body "$src" | rewrite_links "$name"; } > "$dst.tmp"
  mv "$dst.tmp" "$dst"
  echo "synced $name"
done

# demote_headings: shift markdown headings down one level outside code fences
# and drop the file's own H1 (replaced by the section title).
demote_headings() {
  awk '/^```/ { fence = !fence; print; next }
       !fence && /^# / && !seen_h1 { seen_h1 = 1; next }
       !fence && /^#+ / { print "#" $0; next }
       { print }'
}

# Copilot README: instruction count, applyTo table and file tree are
# generated from the instruction files so they can't drift.
README="$ROOT/copilot/README.md"
if [ -f "$README" ]; then
  rows="$TMPDIR_SYNC/rows"; tree="$TMPDIR_SYNC/tree"
  : > "$rows"; : > "$tree"
  count=0; last=""
  for path in "$DEST"/*.instructions.md; do count=$((count + 1)); last=$(basename "$path"); done
  for path in "$DEST"/*.instructions.md; do
    f=$(basename "$path")
    name="${f%.instructions.md}"
    apply=$(sed -n 's/^applyTo:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$path" | head -1)
    # shellcheck disable=SC2016 # literal backticks for markdown code spans
    printf '| `%s` | `%s` |\n' "$name" "$apply" >> "$rows"
    if [ "$f" = "$last" ]; then branch='└──'; else branch='├──'; fi
    printf '│   │   %s %s\n' "$branch" "$f" >> "$tree"
  done
  awk -v rows="$rows" -v tree="$tree" -v count="$count" '
    /^### [0-9]+ Instructions$/ { print "### " count " Instructions"; next }
    { gsub(/It ships [0-9]+ context-aware instructions/, "It ships " count " context-aware instructions") }
    /^\| Instruction \| Applies To \|/ { print; getline; print; while ((getline line < rows) > 0) print line; intable = 1; next }
    intable && /^\|/ { next }
    { intable = 0 }
    /^│   │   [├└]── .*\.instructions\.md$/ { if (!treedone) { while ((getline line < tree) > 0) print line; treedone = 1 }; next }
    { print }
  ' "$README" > "$README.tmp" && mv "$README.tmp" "$README"
  echo "regenerated README instruction table ($count instructions)"
fi

AGENTS="$ROOT/copilot/AGENTS.md"
{
  echo "# Elixir Phoenix Guide — Agent Reference"
  echo ""
  echo "Longer reference material behind the instructions in \`.github/instructions/\`."
  echo "Generated from elixir-phoenix-guide; edit the canonical skills, not this file."
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel="${entry%%|*}"; title="${entry#*|}"
    echo ""
    echo "## $title"
    echo ""
    demote_headings < "$ROOT/skills/$rel"
  done <<< "$SUPPORTING"
} > "$AGENTS.tmp"
mv "$AGENTS.tmp" "$AGENTS"
echo "regenerated AGENTS.md"

mkdir -p "$ROOT/copilot/scripts/lib"
for s in code_quality.exs detect_project.sh run_analysis.sh lib/common.sh; do
  [ -f "$ROOT/scripts/$s" ] && cp "$ROOT/scripts/$s" "$ROOT/copilot/scripts/$s" && echo "copied $s"
done

echo "Done. Review with: cd copilot && git diff"
