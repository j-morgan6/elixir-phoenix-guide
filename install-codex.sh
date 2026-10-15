#!/usr/bin/env bash
# Installs the elixir-phoenix-guide skills for OpenAI Codex by copying them
# into ${CODEX_HOME:-~/.codex}/skills. Codex can also load them as a plugin
# through .codex-plugin/plugin.json. Hooks are Claude Code only.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Installing Elixir Phoenix Guide for Codex${NC}"
echo "========================================="
echo ""

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="$CODEX_HOME/skills"

if [ ! -d "$SOURCE_DIR/skills" ]; then
  echo -e "${RED}Error: skills directory not found at $SOURCE_DIR/skills${NC}"
  exit 1
fi

echo -e "${YELLOW}Installing skills into $CODEX_SKILLS_DIR...${NC}"
mkdir -p "$CODEX_SKILLS_DIR"

SKILL_COUNT=0
for skill_dir in "$SOURCE_DIR/skills"/*; do
  if [ -d "$skill_dir" ] && [ -f "$skill_dir/SKILL.md" ]; then
    skill_name="$(basename "$skill_dir")"
    dest="$CODEX_SKILLS_DIR/$skill_name"
    # Copy the whole directory: several skills link to reference files
    # next to their SKILL.md. Replace any previous copy so removed files go.
    rm -rf "$dest"
    cp -R "$skill_dir" "$dest"
    SKILL_COUNT=$((SKILL_COUNT + 1))
  fi
done

# Claude Code expands ${CLAUDE_SKILL_DIR}; Codex doesn't. Point the
# code-quality skill's script paths at this checkout's scripts/ instead.
CQ="$CODEX_SKILLS_DIR/code-quality/SKILL.md"
if [ -f "$CQ" ]; then
  escaped_scripts=$(printf '%s' "$SOURCE_DIR/scripts/" | sed 's/[&#\\]/\\&/g')
  sed "s#\${CLAUDE_SKILL_DIR}/\.\./\.\./scripts/#${escaped_scripts}#g" "$CQ" > "$CQ.tmp"
  mv "$CQ.tmp" "$CQ"
fi

echo -e "${GREEN}Installed $SKILL_COUNT Codex skills${NC}"
echo ""
echo "Installed to: $CODEX_SKILLS_DIR"
echo "The code-quality skill runs scripts from $SOURCE_DIR/scripts — keep this checkout."
echo -e "${YELLOW}Restart Codex to pick up the new skills.${NC}"
