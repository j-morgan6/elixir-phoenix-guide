#!/usr/bin/env bash
# Packaging checks: version strings agree, manifests are valid JSON, and
# install-codex.sh installs complete skill directories.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

# expect MESSAGE COMMAND... -> passes when COMMAND succeeds
expect() {
  local msg="$1"; shift
  if "$@"; then PASS=$((PASS+1)); else echo "FAIL $msg"; FAIL=$((FAIL+1)); fi
}

VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
for m in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
  v=$(jq -r '.version' "$ROOT/$m" 2>/dev/null || echo "invalid-json")
  expect "$m version $v != VERSION $VERSION" [ "$v" = "$VERSION" ]
done
expect "marketplace.json should not carry a version" \
  jq -e '.plugins[0].version == null' "$ROOT/.claude-plugin/marketplace.json" >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SKILLS="$TMP/codex/skills"
install() { CODEX_HOME="$TMP/codex" bash "$ROOT/install-codex.sh" >/dev/null 2>&1; }
expect "install-codex.sh exited non-zero" install

want=$(find "$ROOT/skills" -name SKILL.md | wc -l | tr -d ' ')
got=$(find "$SKILLS" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
expect "installed $got skills, want $want" [ "$want" = "$got" ]

# Every supporting file a skill ships must be installed next to its SKILL.md.
while IFS= read -r f; do
  rel="${f#"$ROOT/skills/"}"
  expect "missing installed file $rel" [ -f "$SKILLS/$rel" ]
done < <(find "$ROOT/skills" -type f ! -name SKILL.md)

# Relative links in installed skills must resolve.
for md in "$SKILLS"/*/*.md; do
  dir=$(dirname "$md")
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    expect "broken link $link in ${md#"$SKILLS/"}" [ -f "$dir/$link" ]
  done < <(grep -oE '\]\([a-z0-9_-]+\.md\)' "$md" | sed 's/^](//; s/)$//')
done

CQ="$SKILLS/code-quality/SKILL.md"
no_skill_dir_paths() { ! grep -q 'CLAUDE_SKILL_DIR}/\.\./\.\./scripts' "$CQ"; }
expect "code-quality still uses \${CLAUDE_SKILL_DIR} script paths" no_skill_dir_paths
expect "code-quality not pointed at $ROOT/scripts" \
  grep -q "$ROOT/scripts/code_quality.exs" "$CQ"

# Re-running replaces stale files.
touch "$SKILLS/code-quality/stale.md"
install
expect "reinstall left a stale file" [ ! -e "$SKILLS/code-quality/stale.md" ]

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
