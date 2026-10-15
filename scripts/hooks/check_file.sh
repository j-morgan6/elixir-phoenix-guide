#!/usr/bin/env bash
# PostToolUse hook for Write|Edit|MultiEdit on .ex/.exs/.heex files.
#
# Reports findings only on the lines this tool call changed, but evaluates
# them with whole-file context (multi-clause @impl, per-table migration
# indexes). Two tiers:
#   block  - near-certain bugs: stderr + exit 2 (Claude must address them)
#   review - heuristics: hookSpecificOutput.additionalContext JSON + exit 0
# Fails open (exit 0, no output) on missing jq, unreadable input or file.
set -u
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh disable=SC1091
. "$SCRIPT_DIR/../lib/common.sh"

INPUT=$(cat)
META=$(printf '%s' "$INPUT" | jq -r '(.tool_name // ""), (.tool_input.file_path // "")' 2>/dev/null) || exit 0
TOOL=$(printf '%s\n' "$META" | sed -n 1p)
FILE=$(printf '%s\n' "$META" | sed -n 2p)
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0

case "$FILE" in
  */deps/*|*/_build/*|*/node_modules/*|*/.elixir_ls/*) exit 0 ;;
esac
case "$FILE" in
  *_test.exs|*/test/*) exit 0 ;;
esac
case "$FILE" in
  *.ex) KIND="ex" ;;
  *.exs) KIND="exs" ;;
  *.heex) KIND="heex" ;;
  *) exit 0 ;;
esac
IS_MIGRATION=0
case "$FILE" in */migrations/*.exs) IS_MIGRATION=1 ;; esac
SKIP_INSPECT=0
case "$FILE" in */mix/tasks/*) SKIP_INSPECT=1 ;; esac

# --- which lines did this call change? -------------------------------------
# Output: "ALL" (scan everything), "NONE" (nothing added), or "a-b a-b ...".
changed_lines() {
  local out dir base
  case "$TOOL" in
    Edit|MultiEdit)
      # The file is already written. Locate every new_string in it (all
      # occurrences: we can't tell which one was replaced). If a formatter
      # changed the text, fall back to lines whose trimmed text matches a
      # trimmed line of new_string.
      out=$(printf '%s' "$INPUT" | jq -r --rawfile content "$FILE" '
        def nl: split("\n") | length - 1;
        def trim_: gsub("^\\s+|\\s+$"; "");
        (if .tool_name == "MultiEdit" then [.tool_input.edits[]?.new_string // ""]
         else [.tool_input.new_string // ""] end | map(select(length > 0))) as $news
        | if ($news | length) == 0 then "NONE"
          else
            ([ $news[] as $s
               | ($content | split($s)) as $parts
               | ($s | nl) as $snl
               | (if ($s | endswith("\n")) and $snl > 0 then $snl - 1 else $snl end) as $span
               | select(($parts | length) > 1)
               | foreach range(0; ($parts | length) - 1) as $i (
                   {line: 1, start: 1};
                   .line += ($parts[$i] | nl) | .start = .line | .line += $snl;
                   "\(.start)-\(.start + $span)")
             ]) as $exact
            | if ($exact | length) > 0 then $exact | join(" ")
              else
                ([ $news[] | split("\n")[] | trim_ | select(length > 0) ]
                 | map({(.): true}) | add // {}) as $want
                | [ $content | split("\n") | to_entries[]
                    | select($want[.value | trim_]) | "\(.key + 1)-\(.key + 1)" ]
                | if length > 0 then join(" ") else "ALL" end
              end
          end' 2>/dev/null) || out=ALL
      ;;
    Write)
      # Added lines vs the git index when the file is tracked; otherwise the
      # whole file is new to us.
      out=ALL
      dir=$(dirname "$FILE"); base=$(basename "$FILE")
      if command -v git >/dev/null 2>&1 &&
         (cd "$dir" && git ls-files --error-unmatch -- "$base") >/dev/null 2>&1; then
        out=$( (cd "$dir" && git diff -U0 --no-color --no-ext-diff -- "$base") 2>/dev/null | awk '
          /^@@/ {
            if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
              s = substr($0, RSTART + 1, RLENGTH - 1); n = split(s, p, ",")
              start = p[1] + 0; cnt = (n > 1) ? p[2] + 0 : 1
              if (cnt > 0) { printf "%s%d-%d", sep, start, start + cnt - 1; sep = " " }
            }
          }
          END { if (sep == "") print "NONE"; else print "" }') || out=ALL
      fi
      ;;
    *) out=ALL ;;
  esac
  [ -n "$out" ] || out=ALL
  printf '%s' "$out"
}
RANGES=$(changed_lines)
[ "$RANGES" = "NONE" ] && exit 0

# --- project facts cached by detect_project.sh at SessionStart --------------
HAS_SCOPE=false
CACHE=$(epg_cache_file "$(epg_project_root)")
if [ -f "$CACHE" ] && grep -q '"phoenix_has_scope":[[:space:]]*true' "$CACHE" 2>/dev/null; then
  HAS_SCOPE=true
fi

# --- the checks -------------------------------------------------------------
# Output lines: "<block|review>\t<message> (line N, M)".
FINDINGS=$(awk -v ranges="$RANGES" -v kind="$KIND" -v is_mig="$IS_MIGRATION" \
  -v skip_inspect="$SKIP_INSPECT" -v has_scope="$HAS_SCOPE" '
function strip_comment(s,   i, c, q, L) {
  if (index(s, "#") == 0) return s
  q = 0; L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; continue }
    if (c == "\"") q = !q
    else if (c == "#" && !q && substr(s, i + 1, 1) != "{") return substr(s, 1, i - 1)
  }
  return s
}
function dyn_interp(s,   t) {
  t = s
  gsub(/#[{]@[A-Za-z_][A-Za-z0-9_]*[}]/, "", t)   # #{@module_attr} is static
  return t ~ /#[{]/
}
function flag(id, ln) {
  if (!(all || chg[ln])) return
  if (seen[id, ln]) return
  seen[id, ln] = 1
  where[id] = (where[id] == "") ? ln : where[id] ", " ln
  if (!(id in order)) { order[id] = ++norder; ids[norder] = id }
}
# def name and arity (-1 when the head spans lines) of a def line
function def_head(s,   rest, name, i, c, depth, commas, q, L, sawarg) {
  rest = s
  sub(/^[[:space:]]*def(p|macro|macrop)?[[:space:]]+/, "", rest)
  if (!match(rest, /^[a-z_][A-Za-z0-9_]*[?!]?/)) { dh_name = ""; dh_arity = -1; return }
  name = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
  dh_name = name
  if (substr(rest, 1, 1) != "(") { dh_arity = (rest ~ /^[[:space:]]+[^,d]/) ? -1 : 0; return }
  depth = 0; commas = 0; q = 0; sawarg = 0; L = length(rest)
  for (i = 1; i <= L; i++) {
    c = substr(rest, i, 1)
    if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; sawarg = 1; continue }
    if (c == "(" || c == "[" || c == "{") { depth++; if (depth > 1) sawarg = 1; continue }
    if (c == ")" || c == "]" || c == "}") {
      depth--
      if (depth == 0) { dh_arity = sawarg ? commas + 1 : 0; return }
      continue
    }
    if (c == "," && depth == 1) commas++
    else if (c !~ /[[:space:]]/) sawarg = 1
  }
  dh_arity = -1
}
# regexes are passed as strings: a bare /re/ argument would be matched against $0
function capture(s, re, prefix_re,   t) {
  if (!match(s, re)) return ""
  t = substr(s, RSTART, RLENGTH)
  sub(prefix_re, "", t)
  return t
}
BEGIN {
  all = (ranges == "ALL")
  if (!all) {
    nr = split(ranges, rr, " ")
    for (k = 1; k <= nr; k++) {
      split(rr[k], ab, "-")
      for (x = ab[1] + 0; x <= ab[2] + 0; x++) chg[x] = 1
    }
  }
  is_ex = (kind == "ex" || kind == "exs")
  tier["sql"] = "block";       msg["sql"] = "SQL built by string interpolation in Repo.query/SQL.query - SQL injection. Pass values as parameters: Repo.query(\"... WHERE id = $1\", [id])."
  tier["fragment"] = "block";  msg["fragment"] = "Interpolation inside fragment() - Ecto rejects this at compile time and it would be SQL injection. Use ? placeholders: fragment(\"lower(?)\", field)."
  tier["extredir"] = "block";  msg["extredir"] = "redirect(external: params...) - open redirect to a user-supplied URL. Use redirect(to: ~p\"...\") or check the host against an allowlist first."
  tier["formfor"] = "block";   msg["formfor"] = "form_for was removed in phoenix_html 4 - use <.form for={@form} ...> with to_form/1."
  tier["livenav"] = "block";   msg["livenav"] = "live_redirect/live_patch/push_redirect are deprecated - use <.link navigate={...}>/<.link patch={...}> or push_navigate/push_patch."
  tier["toatom"] = "review";   msg["toatom"] = "String.to_atom/1 - atoms are never garbage-collected; on user input this can exhaust the atom table. Map known strings explicitly or use String.to_existing_atom/1."
  tier["raw"] = "review";      msg["raw"] = "raw/1 bypasses HTML escaping - XSS if the content can contain user input. Make sure it is sanitized or trusted."
  tier["logger"] = "review";   msg["logger"] = "Logger message interpolates a sensitive value (password/token/secret/key) - redact it or log an identifier instead."
  tier["inspect"] = "review";  msg["inspect"] = "IO.inspect/dbg left in lib code - remove before committing (use Logger for intentional output)."
  tier["timing"] = "review";   msg["timing"] = "Secret/token compared with == - not constant-time. Use Plug.Crypto.secure_compare/2."
  tier["impl"] = "review";     msg["impl"] = "Callback without @impl true on its first clause - add @impl true above it."
  tier["migidx"] = "review";   msg["migidx"] = "references() column with no index on that table in this migration - add create index(:table, [:column]) (Postgres does not index foreign keys automatically)."
  tier["ondelete"] = "review"; msg["ondelete"] = "references() without on_delete: - the default is :nothing; choose :delete_all, :nilify_all or :restrict explicitly."
  tier["curuser"] = "review";  msg["curuser"] = "This project uses Phoenix 1.8 scopes - use @current_scope (and @current_scope.user) rather than @current_user."
}
{ raw[NR] = $0 }
END {
  n = NR
  # ---- pass 1: blank out comments and @doc/@moduledoc/@typedoc text ----
  indoc = ""; inhc = 0
  for (i = 1; i <= n; i++) {
    line = raw[i]
    if (indoc != "") { if (index(line, indoc)) indoc = ""; code[i] = ""; continue }
    if (inhc) {
      if (index(line, "--%>")) { inhc = 0; line = substr(line, index(line, "--%>") + 4) }
      else { code[i] = ""; continue }
    }
    if (is_ex && line ~ /^[[:space:]]*@(moduledoc|doc|typedoc|shortdoc)([[:space:]]|$)/) {
      code[i] = "@doc"
      if (line ~ /"""/) indoc = "\"\"\""
      else if (line ~ /'\'''\'''\''/) indoc = "'\'''\'''\''"
      continue
    }
    if (is_ex && line ~ /^[[:space:]]*#/) { code[i] = ""; continue }
    while (match(line, /<%!--/)) {
      rest = substr(line, RSTART + 5)
      if (index(rest, "--%>")) line = substr(line, 1, RSTART - 1) substr(rest, index(rest, "--%>") + 4)
      else { line = substr(line, 1, RSTART - 1); inhc = 1; break }
    }
    gsub(/<!--.*-->/, "", line)
    code[i] = is_ex ? strip_comment(line) : line
  }

  # ---- pass 2: line checks ----
  impl_pending = 0; last_name = ""; last_arity = -2
  cur_table = ""
  for (i = 1; i <= n; i++) {
    c = code[i]
    if (c ~ /^[[:space:]]*$/) continue
    isdef = (c ~ /^[[:space:]]*def(p|macro|macrop)?[[:space:]]+[a-z_]/)

    if (is_ex) {
      # SQL interpolation: single-line string or a """ heredoc argument
      if (match(c, /(Repo|SQL)[.]query!?[(]/)) {
        rest = substr(c, RSTART + RLENGTH - 1)
        if (rest ~ /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?~?[sS]?"""/) {
          for (j = i + 1; j <= n && j <= i + 200; j++) {
            if (index(raw[j], "\"\"\"")) break
            if (dyn_interp(raw[j])) { if (all || chg[j]) flag("sql", j); else flag("sql", i) }
          }
        } else if (match(rest, /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?"([^"\\]|\\.)*"/)) {
          if (dyn_interp(substr(rest, 1, RLENGTH))) flag("sql", i)
        } else if (rest ~ /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?"/ && dyn_interp(rest)) {
          flag("sql", i)
        }
      }
      if (c ~ /fragment[(]"[^"]*#[{]/) flag("fragment", i)
      if (c ~ /external:[[:space:]]*(conn[.])?(query_|body_|path_)?params([^A-Za-z0-9_]|$)/) flag("extredir", i)
      if (c ~ /String[.]to_atom([^A-Za-z0-9_?!]|$)/) flag("toatom", i)
      lc = tolower(c)
      if (lc ~ /logger[.][a-z_]+[(]/ && lc ~ /#[{][^}]*(password|passwd|secret|token|api_key|apikey|private_key|credential|authorization)/) flag("logger", i)
      if (kind == "ex" && !skip_inspect && (c ~ /IO[.]inspect([^A-Za-z0-9_]|$)/ || c ~ /(^|[^A-Za-z0-9_.:])dbg[(]/)) flag("inspect", i)
      if (c ~ /(token|secret|api_key|signature)[[:space:]]*==[[:space:]]*[a-z_]/ || c ~ /[a-z_][[:space:]]*==[[:space:]]*(token|secret|api_key|signature)([^A-Za-z0-9_]|$)/) {
        if (c !~ /==[[:space:]]*(nil|true|false)([^A-Za-z0-9_]|$)/ && c !~ /(^|[^A-Za-z0-9_.])(nil|true|false)[[:space:]]*==/) flag("timing", i)
      }
    }

    # deprecated/removed APIs and XSS (also .heex); a project defining its
    # own helper of that name is not flagged on the def line itself
    defines = ""
    if (isdef) defines = capture(c, "def(p|macro|macrop)?[[:space:]]+[a-z_]+", "^def(p|macro|macrop)?[[:space:]]+")
    if (defines != "form_for" && c ~ /(^|[^A-Za-z0-9_:])form_for([(]|[[:space:]]+[@a-z])/) flag("formfor", i)
    if (defines !~ /^(live_redirect|live_patch|push_redirect)$/ && c ~ /(^|[^A-Za-z0-9_:])(live_redirect|live_patch|push_redirect)([^A-Za-z0-9_]|$)/) flag("livenav", i)
    if (defines != "raw" && (c ~ /(^|[^A-Za-z0-9_.:])raw([(]|[[:space:]]+@)/ || c ~ /HTML[.]raw[(]/)) flag("raw", i)
    if (has_scope == "true" && c ~ /(@|assigns[.])current_user([^A-Za-z0-9_]|$)/) flag("curuser", i)

    # @impl: first clause of a callback needs it; later clauses of the same
    # name/arity do not. Blank lines, comments and attributes may intervene.
    if (kind == "ex") {
      if (c ~ /^[[:space:]]*defmodule[[:space:]]/) { last_name = ""; impl_pending = 0 }
      else if (isdef) {
        def_head(c)
        same = (dh_name == last_name && (dh_arity == last_arity || dh_arity < 0 || last_arity < 0))
        if (c ~ /^[[:space:]]*def[[:space:]]+(mount|handle_params|handle_event|handle_info|handle_call|handle_cast|handle_continue|handle_async|terminate)[(]/ && !same && !impl_pending) flag("impl", i)
        last_name = dh_name; last_arity = dh_arity; impl_pending = 0
      }
      else if (c ~ /^[[:space:]]*@impl([[:space:]]|$)/) impl_pending = 1
      else if (c ~ /^[[:space:]]*@/) { }
      else impl_pending = 0
    }

    # migrations: collect references and indexes per table
    if (is_mig == 1) {
      if (c ~ /(create|create_if_not_exists|alter)[[:space:]]*[(]?[[:space:]]*table[(]/) {
        cur_table = capture(c, "table[(][[:space:]]*:?\"?[A-Za-z0-9_]+", "^table[(][[:space:]]*:?\"?")
      }
      if (c ~ /(add|add_if_not_exists|modify)[[:space:]]+:?[A-Za-z0-9_]+,[[:space:]]*references[(]/) {
        nref++
        refcol[nref] = capture(c, "(add|add_if_not_exists|modify)[[:space:]]+:?[A-Za-z0-9_]+", "^(add|add_if_not_exists|modify)[[:space:]]+:?")
        reftab[nref] = cur_table; refline[nref] = i
        # on_delete may sit on a continuation line of the same call
        buf = c; depth = gsub(/[(]/, "(", buf) - gsub(/[)]/, ")", buf)
        for (j = i + 1; depth > 0 && j <= n && j <= i + 6; j++) {
          buf = buf " " code[j]; t = code[j]; depth += gsub(/[(]/, "(", t) - gsub(/[)]/, ")", t)
        }
        if (buf !~ /on_delete:/) flag("ondelete", i)
      }
      if (c ~ /(unique_)?index[(][[:space:]]*:?"?[A-Za-z0-9_]+"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?"?[A-Za-z0-9_]+/) {
        t = capture(c, "index[(][[:space:]]*:?\"?[A-Za-z0-9_]+\"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?\"?[A-Za-z0-9_]+", "^index[(][[:space:]]*:?\"?")
        split(t, parts, /"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?"?/)
        idx[parts[1], parts[2]] = 1
      }
    }
  }
  if (is_mig == 1) {
    for (k = 1; k <= nref; k++) if (!((reftab[k], refcol[k]) in idx)) flag("migidx", refline[k])
  }

  for (k = 1; k <= norder; k++) {
    id = ids[k]
    printf "%s\t%s (%s %s)\n", tier[id], msg[id], (index(where[id], ",") ? "lines" : "line"), where[id]
  }
}' "$FILE" 2>/dev/null) || exit 0

[ -n "$FINDINGS" ] || exit 0

BLOCK=$(printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "block" { print "- " $2 }')
REVIEW=$(printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "review" { print "- " $2 }')

if [ -n "$BLOCK" ]; then
  {
    echo "elixir-phoenix-guide: $FILE has problems on the lines just written:"
    printf '%s\n' "$BLOCK"
    if [ -n "$REVIEW" ]; then
      echo "Also review (may be intentional):"
      printf '%s\n' "$REVIEW"
    fi
    echo "Fix these before continuing."
  } >&2
  exit 2
fi

TEXT="elixir-phoenix-guide review notes for $FILE (lines just written; fix or confirm they are intentional):
$REVIEW"
jq -n --arg c "$TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
