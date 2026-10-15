#!/usr/bin/env bash
# Packaging checks: version strings agree, manifests are valid JSON,
# install-codex.sh installs complete skill directories, and skill
# frontmatter only uses keys Claude Code reads.
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

# Skill frontmatter: only keys Claude Code reads, name matches the directory,
# a unique "Use when…" description, and a "Verified against" line under the H1.
DESCS="$TMP/descriptions"
: > "$DESCS"
for skill in "$ROOT"/skills/*/SKILL.md; do
  dir=$(basename "$(dirname "$skill")")
  fm=$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$skill")
  keys=$(printf '%s\n' "$fm" | grep -oE '^[a-z_-]+:' | tr -d ':' | sort | tr '\n' ' ')
  expect "$dir: frontmatter keys are '$keys' (want 'description name ')" [ "$keys" = "description name " ]
  name=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p')
  expect "$dir: name '$name' doesn't match directory" [ "$name" = "$dir" ]
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | sed 's/^"//; s/"$//')
  case "$desc" in "Use when "*) d_ok=1 ;; *) d_ok=0 ;; esac
  expect "$dir: description must start with 'Use when'" [ "$d_ok" = 1 ]
  expect "$dir: description is ${#desc} chars (max 1024)" [ "${#desc}" -le 1024 ]
  printf '%s\n' "$desc" >> "$DESCS"
  verified=$(awk '/^---$/ {n++; next} n >= 2 && /^# / {h=1; next} h && NF {print; exit}' "$skill")
  case "$verified" in "> Verified against "*) v_ok=1 ;; *) v_ok=0 ;; esac
  expect "$dir: first line after the H1 must be '> Verified against …'" [ "$v_ok" = 1 ]
done
dupes=$(sort "$DESCS" | uniq -d | wc -l | tr -d ' ')
expect "$dupes duplicate skill descriptions" [ "$dupes" = 0 ]

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
