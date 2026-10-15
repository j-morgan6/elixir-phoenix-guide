#!/usr/bin/env bash
# Tests for scripts/code_quality.exs and scripts/run_analysis.sh.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/tests/code_quality/fixtures"
# Allow pointing the harness at a scratch copy of the script (used to prove
# the assertions actually discriminate against the pre-fix behavior).
SCRIPT="${CODE_QUALITY_SCRIPT:-$ROOT/scripts/code_quality.exs}"
SH="${BASH:-bash}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
cq() { OUT=$(elixir "$SCRIPT" "$@" 2>&1); RC=$?; }

# 1. Guarded defs are reported under their real name, never as when/2, and
#    tiny bodies ({:ok, id}) are below the size threshold.
cq all "$FIX/guarded.ex"
if has 'when/2' || has 'Duplicated'; then fail 'guarded.ex: tiny guarded bodies reported (or as when/2)'; else pass; fi

# 2. Duplication across differently named functions in different files.
cq scan "$FIX"
if has 'fetch_thing/1' && has 'load_thing/1'; then pass; else fail "renamed duplicate fetch_thing/load_thing not detected: $OUT"; fi
if has 'when/2'; then fail 'guarded duplicates reported as when/2'; else pass; fi

# 3. Same-named duplicates are reported under the real name.
if has 'process_thing/1  '; then pass; else fail 'same-name duplicate process_thing/1 not reported'; fi

# 4. Renamed variables, different literals, different module/function names.
if has 'summarize/1' && has 'build_week_summary/1'; then pass; else fail "renamed copy with different literals not detected: $OUT"; fi
if [ "$RC" -eq 1 ]; then pass; else fail "scan with findings should exit 1 (got $RC)"; fi

# 5. Single-file mode compares against the file's whole tree.
cq duplication "$FIX/guarded_a.ex"
if has 'load_thing/1'; then pass; else fail "single-file mode missed duplicate in sibling file: $OUT"; fi

# 6. No unused-function detector: ?/! names and function components never
#    produce "unused" claims, and `unused` points at the compiler.
cq all "$FIX/predicates.ex"
if has 'never called' || has 'Unused'; then fail "unused-function claims still produced: $OUT"; else pass; fi
cq unused "$FIX/predicates.ex"
if has 'mix compile --warnings-as-errors'; then pass; else fail "unused command should point at the compiler: $OUT"; fi

# 7. Branch complexity (renamed from "ABC").
cq complexity "$FIX/complex.ex"
if has 'classify/3' && has 'branch complexity'; then pass; else fail "complex.ex not reported with branch complexity: $OUT"; fi
if has 'ABC'; then fail 'output still says ABC'; else pass; fi
cq complexity "$FIX/guarded_c.ex"
if has 'No code quality issues found' && [ "$RC" -eq 0 ]; then pass; else fail "simple function flagged as complex: $OUT"; fi

# 8. run_analysis.sh: umbrella root without lib/ scans apps/*/lib together.
U="$TMP/umbrella"
mkdir -p "$U/apps/a/lib" "$U/apps/b/lib"
cp "$FIX/guarded_a.ex" "$U/apps/a/lib/"
cp "$FIX/guarded_b.ex" "$U/apps/b/lib/"
OUT=$("$SH" "$ROOT/scripts/run_analysis.sh" "$U" 2>&1); RC=$?
if has 'fetch_thing/1' && has 'load_thing/1'; then pass; else fail "umbrella cross-app duplicate not found: $OUT"; fi
OUT=$("$SH" "$ROOT/scripts/run_analysis.sh" "$TMP/nothing" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && has 'No lib/'; then pass; else fail "missing lib/ should exit 1 with a message: $OUT"; fi

echo "pass=$passes fail=$failures"
if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo PASS
