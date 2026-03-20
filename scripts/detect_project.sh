#!/usr/bin/env bash
# Project Detection System for Elixir Phoenix Guide Plugin
# Parses mix.exs to detect project characteristics that change hook behavior.
# Writes cache to .elixir-phoenix-guide-project.json in project root.

set -euo pipefail

# Find project root (look for mix.exs)
find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/mix.exs" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_ROOT=$(find_project_root 2>/dev/null) || exit 0
MIX_FILE="$PROJECT_ROOT/mix.exs"
CACHE_FILE="$PROJECT_ROOT/.elixir-phoenix-guide-project.json"

if [ ! -f "$MIX_FILE" ]; then
  exit 0
fi

# Detect Phoenix version from mix.exs deps
detect_phoenix_version() {
  local version=""
  # Match {:phoenix, "~> X.Y"} or {:phoenix, "~> X.Y.Z"}
  version=$(grep -oE '\{:phoenix,\s*"~>\s*[0-9]+\.[0-9]+(\.[0-9]+)?"' "$MIX_FILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [ -z "$version" ]; then
    # Try {:phoenix, ">= X.Y.Z"} format
    version=$(grep -oE '\{:phoenix,\s*">=\s*[0-9]+\.[0-9]+(\.[0-9]+)?"' "$MIX_FILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  fi
  if [ -z "$version" ]; then
    # Check mix.lock for exact version
    local lock_file="$PROJECT_ROOT/mix.lock"
    if [ -f "$lock_file" ]; then
      version=$(grep -oE '"phoenix".*"[0-9]+\.[0-9]+\.[0-9]+"' "$lock_file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    fi
  fi
  echo "${version:-unknown}"
}

# Detect if LiveView is present
detect_liveview() {
  if grep -qE ':phoenix_live_view' "$MIX_FILE" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# Detect Ecto adapter
detect_ecto_adapter() {
  if grep -qE ':postgrex' "$MIX_FILE" 2>/dev/null; then
    echo "postgres"
  elif grep -qE ':ecto_sqlite3' "$MIX_FILE" 2>/dev/null; then
    echo "sqlite"
  elif grep -qE ':myxql' "$MIX_FILE" 2>/dev/null; then
    echo "mysql"
  elif grep -qE ':ecto_sql|:ecto' "$MIX_FILE" 2>/dev/null; then
    echo "unknown"
  else
    echo "none"
  fi
}

# Detect if Oban is present
detect_oban() {
  if grep -qE ':oban' "$MIX_FILE" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# Detect if project has Ecto at all
detect_ecto() {
  if grep -qE ':ecto_sql|:ecto\b' "$MIX_FILE" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# Detect Phoenix app name
detect_app_name() {
  grep -oE 'app:\s*:[a-z_]+' "$MIX_FILE" 2>/dev/null | grep -oE ':[a-z_]+$' | tr -d ':' | head -1
}

PHOENIX_VERSION=$(detect_phoenix_version)
HAS_LIVEVIEW=$(detect_liveview)
ECTO_ADAPTER=$(detect_ecto_adapter)
HAS_OBAN=$(detect_oban)
HAS_ECTO=$(detect_ecto)
APP_NAME=$(detect_app_name)

# Determine Phoenix major.minor for comparison
PHOENIX_MAJOR_MINOR=""
if [ "$PHOENIX_VERSION" != "unknown" ]; then
  PHOENIX_MAJOR_MINOR=$(echo "$PHOENIX_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
fi

# Determine if this is Phoenix 1.8+ (has Scope struct, scoped contexts)
HAS_SCOPE="false"
if [ -n "$PHOENIX_MAJOR_MINOR" ]; then
  MAJOR=$(echo "$PHOENIX_MAJOR_MINOR" | cut -d. -f1)
  MINOR=$(echo "$PHOENIX_MAJOR_MINOR" | cut -d. -f2)
  if [ "$MAJOR" -gt 1 ] || ([ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 8 ]); then
    HAS_SCOPE="true"
  fi
fi

# Write cache file (no jq dependency — pure bash)
cat > "$CACHE_FILE" <<EOF
{
  "plugin_version": "2.2.0",
  "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "app_name": "${APP_NAME:-unknown}",
  "phoenix_version": "$PHOENIX_VERSION",
  "phoenix_has_scope": $HAS_SCOPE,
  "has_liveview": $HAS_LIVEVIEW,
  "has_ecto": $HAS_ECTO,
  "ecto_adapter": "$ECTO_ADAPTER",
  "has_oban": $HAS_OBAN
}
EOF

# Output summary for Claude's context
echo "📋 Project detected: ${APP_NAME:-unknown}"
echo "   Phoenix: $PHOENIX_VERSION$([ "$HAS_SCOPE" = "true" ] && echo ' (Scope struct)' || echo '')"
echo "   LiveView: $HAS_LIVEVIEW"
echo "   Ecto: $HAS_ECTO ($ECTO_ADAPTER)"
echo "   Oban: $HAS_OBAN"
echo "   Cache: $CACHE_FILE"
