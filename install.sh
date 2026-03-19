#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Installing Elixir Claude Code Optimization${NC}"
echo "==========================================="
echo ""

# Check if Claude Code is installed
if ! command -v claude &> /dev/null; then
    echo -e "${RED}Error: Claude Code CLI not found${NC}"
    echo "Please install Claude Code first: https://claude.ai/download"
    exit 1
fi

# Create Claude directory if it doesn't exist
CLAUDE_DIR="$HOME/.claude"
if [ ! -d "$CLAUDE_DIR" ]; then
    echo -e "${YELLOW}Creating ~/.claude directory...${NC}"
    mkdir -p "$CLAUDE_DIR"
fi

# Detect if running from git clone or curl
if [ -d "$(dirname "$0")/skills" ]; then
    # Running from cloned repo
    SOURCE_DIR="$(dirname "$0")"
    echo -e "${GREEN}Installing from local repository...${NC}"
else
    # Running from curl, need to download
    echo -e "${GREEN}Downloading from GitHub...${NC}"
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"

    REPO_URL="https://github.com/j-morgan6/elixir-phoenix-guide"

    if command -v git &> /dev/null; then
        git clone "$REPO_URL" .
    else
        echo -e "${RED}Error: git not found and running from curl${NC}"
        echo "Please install git or clone the repository manually"
        exit 1
    fi

    SOURCE_DIR="$TEMP_DIR"
fi

# Install skills (must be in subdirectories with SKILL.md filename)
echo -e "${YELLOW}Installing skills...${NC}"
mkdir -p "$CLAUDE_DIR/skills"
SKILL_COUNT=0
for skill_dir in "$SOURCE_DIR/skills"/*; do
    if [ -d "$skill_dir" ]; then
        skill_name=$(basename "$skill_dir")
        mkdir -p "$CLAUDE_DIR/skills/$skill_name"
        cp "$skill_dir/SKILL.md" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
        SKILL_COUNT=$((SKILL_COUNT + 1))
    fi
done
echo -e "${GREEN}✓ Installed $SKILL_COUNT skills${NC}"

# Install hooks (merge into settings.json)
echo -e "${YELLOW}Installing hooks into settings.json...${NC}"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Backup existing settings
cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup"

# Merge hooks using jq if available, otherwise manual merge
if command -v jq &> /dev/null; then
  jq -s '.[0] * .[1]' "$SETTINGS_FILE" "$SOURCE_DIR/hooks-settings.json" > "$SETTINGS_FILE.tmp"
  mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  echo -e "${GREEN}✓ Installed 15 hooks (merged with jq)${NC}"
else
  echo -e "${YELLOW}⚠ jq not found. Please manually merge hooks-settings.json into ~/.claude/settings.json${NC}"
  echo -e "${YELLOW}  See INSTALL-HOOKS.md for instructions${NC}"
fi

# Install analysis scripts
echo -e "${YELLOW}Installing analysis scripts...${NC}"
mkdir -p "$CLAUDE_DIR/scripts/elixir-phoenix-guide"
cp "$SOURCE_DIR/scripts/code_quality.exs" "$CLAUDE_DIR/scripts/elixir-phoenix-guide/"
cp "$SOURCE_DIR/scripts/detect_template_duplication.sh" "$CLAUDE_DIR/scripts/elixir-phoenix-guide/"
cp "$SOURCE_DIR/scripts/run_analysis.sh" "$CLAUDE_DIR/scripts/elixir-phoenix-guide/"
chmod +x "$CLAUDE_DIR/scripts/elixir-phoenix-guide/"*.sh
chmod +x "$CLAUDE_DIR/scripts/elixir-phoenix-guide/"*.exs
echo -e "${GREEN}✓ Installed 3 analysis scripts${NC}"

# Install agent documentation
echo -e "${YELLOW}Installing agent documentation...${NC}"
mkdir -p "$CLAUDE_DIR/agents"
cp -r "$SOURCE_DIR/agents/"* "$CLAUDE_DIR/agents/"
echo -e "${GREEN}✓ Installed 4 agent docs${NC}"

# Copy CLAUDE.md template to current directory (optional)
if [ ! -f "CLAUDE.md" ] && [ -f "$SOURCE_DIR/CLAUDE.md.template" ]; then
    echo -e "${YELLOW}Would you like to copy CLAUDE.md template to current directory? (y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        cp "$SOURCE_DIR/CLAUDE.md.template" "./CLAUDE.md"
        echo -e "${GREEN}✓ CLAUDE.md template copied (edit for your project)${NC}"
    fi
fi

# Cleanup if we downloaded
if [ "$SOURCE_DIR" = "$TEMP_DIR" ]; then
    cd ~
    rm -rf "$TEMP_DIR"
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Installed components:"
echo "  • 14 Skills (elixir-essentials, phoenix-liveview-essentials, ecto-essentials, phoenix-uploads, testing-essentials, otp-essentials, oban-essentials, code-quality, phoenix-liveview-auth, ecto-changeset-patterns, phoenix-auth-customization, phoenix-pubsub-patterns, phoenix-authorization-patterns, ecto-nested-associations)"
echo "  • 15 Hooks (14 PreToolUse + 1 PostToolUse code quality)"
echo "  • 3 Analysis scripts (code duplication, template duplication, full project scan)"
echo "  • 4 Agent docs (project-structure, liveview-checklist, ecto-conventions, testing-guide)"
echo ""
echo "Hooks are now in ~/.claude/settings.json"
echo "Backup saved to ~/.claude/settings.json.backup"
echo ""
echo "These customizations will apply to all your Elixir projects."
echo ""
echo "Optional: Copy CLAUDE.md.template to your project root and customize it:"
echo "  cp ~/.claude/agents/../CLAUDE.md.template /path/to/your/project/CLAUDE.md"
echo ""
echo -e "${YELLOW}Restart Claude Code to load the new configuration.${NC}"
