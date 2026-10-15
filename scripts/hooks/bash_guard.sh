#!/usr/bin/env bash
# PreToolUse hook for Bash. Blocks (stderr + exit 2) commands that destroy
# data or remote history, in Elixir projects only:
#   - mix ecto.reset / mix ecto.drop, unless MIX_ENV=test for that command
#   - git push --force / -f / combined short flags with f / +refspec
#     (--force-with-lease and --force-if-includes are allowed)
# Opt-out: EPG_ALLOW=force_push,ecto_reset,ecto_drop in the hook's environment,
# exported earlier in the same command line, or as a prefix of the command.
#
# The command is tokenised by a small awk scanner: quoted text, comments and
# heredoc bodies are neutralised, then the line is split on ; && || | & ( )
# $( ` and newlines. Each segment's command words are then examined.
# Known limits: commands hidden in eval/bash -c "..."/sh -c strings, aliases,
# shell functions, variables used as command names, and $(...) inside double
# quotes are not inspected.
set -u
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh disable=SC1091
. "$SCRIPT_DIR/../lib/common.sh"

epg_is_elixir_project "${CLAUDE_PROJECT_DIR:-$PWD}" || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# One segment per output line. Inside quotes, whitespace and shell
# metacharacters become "_" so quoted text stays a single inert word.
SEGMENTS=$(printf '%s' "$CMD" | awk '
{ s = (NR > 1) ? s "\n" $0 : $0 }
END {
  L = length(s); out = ""; st = 0; nhd = 0
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (st == 1) {
      if (c == "\047") st = 0
      else out = out ((c ~ /[[:space:];&|()<>`$]/) ? "_" : c)
      continue
    }
    if (st == 2) {
      if (c == "\\") { i++; out = out "_"; continue }
      if (c == "\"") st = 0
      else out = out ((c ~ /[[:space:];&|()<>`$]/) ? "_" : c)
      continue
    }
    if (c == "\\") {
      i++; n2 = substr(s, i, 1)
      out = out ((n2 == "\n") ? " " : ((n2 ~ /[[:space:]]/) ? "_" : n2))
      continue
    }
    if (c == "\047") { st = 1; continue }
    if (c == "\"") { st = 2; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|()]/)) {
      while (i <= L && substr(s, i + 1, 1) != "\n") i++
      continue
    }
    if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
      j = i + 2
      if (substr(s, j, 1) == "-") j++
      while (substr(s, j, 1) ~ /[ \t]/) j++
      w = ""
      while (j <= L && substr(s, j, 1) !~ /[[:space:];&|()<>]/) { w = w substr(s, j, 1); j++ }
      gsub(/[\047"\\]/, "", w)
      if (w != "") hd[++nhd] = w
      i = j - 1
      out = out " "
      continue
    }
    if (c == "\n") {
      out = out "\n"
      if (nhd > 0) {
        pos = i + 1
        for (h = 1; h <= nhd; h++) {
          while (pos <= L) {
            rest = substr(s, pos); e = index(rest, "\n")
            if (e == 0) { t = rest; pos = L + 1 } else { t = substr(rest, 1, e - 1); pos += e }
            sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
            if (t == hd[h]) break
          }
        }
        nhd = 0; i = pos - 1
      }
      continue
    }
    if (c == "&") {
      p = substr(s, i - 1, 1); q = substr(s, i + 1, 1)
      if (p == ">" || p == "<" || q == ">") { out = out c; continue }
      out = out "\n"; continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") { out = out "\n"; i++; continue }
    if (c == ";" || c == "|" || c == "(" || c == ")" || c == "`") { out = out "\n"; continue }
    out = out c
  }
  print out
}')

has_allow() { # $1 = token, $2.. = comma lists
  local tok="$1" list
  shift
  for list in "$@"; do
    case ",$list," in *",$tok,"*|*",all,"*) return 0 ;; esac
  done
  return 1
}

block() {
  printf 'elixir-phoenix-guide blocked this command: %s\n' "$1" >&2
  exit 2
}

EXP_MIX_ENV=""; EXP_ALLOW=""
HOOK_MIX_ENV="${MIX_ENV:-}"; HOOK_ALLOW="${EPG_ALLOW:-}"

check_segment() {
  local seg_env="" seg_allow="" w name val cmd sub a cluster env tok task
  # strip leading assignments, wrappers and shell keywords
  while [ $# -gt 0 ]; do
    w="$1"
    case "$w" in
      *=*)
        name="${w%%=*}"; val="${w#*=}"
        case "$name" in
          ''|[0-9]*|*[!A-Za-z0-9_]*) break ;;
        esac
        [ "$name" = MIX_ENV ] && seg_env="$val"
        [ "$name" = EPG_ALLOW ] && seg_allow="$val"
        shift ;;
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|-C|-S) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      '{'|'}'|'!'|if|then|else|elif|do|while|until|time|nohup|command|exec|builtin|sudo|xargs) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  cmd="${1##*/}"; shift

  case "$cmd" in
    export)
      for a in "$@"; do
        case "$a" in
          MIX_ENV=*) EXP_MIX_ENV="${a#MIX_ENV=}" ;;
          EPG_ALLOW=*) EXP_ALLOW="${a#EPG_ALLOW=}" ;;
        esac
      done ;;
    mix)
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      [ $# -gt 0 ] || return 0
      if [ "$1" = "do" ]; then
        shift
        set -f
        # shellcheck disable=SC2046 # split "a, b + c" into task words
        set -- $(printf '%s\n' "$*" | tr ',+' '  ')
        set +f
      else
        set -- "$1"
      fi
      env="${seg_env:-${EXP_MIX_ENV:-${HOOK_MIX_ENV:-dev}}}"
      for task in "$@"; do
        case "$task" in
          ecto.reset|ecto.drop)
            [ "$env" = test ] && continue
            tok=ecto_reset; [ "$task" = ecto.drop ] && tok=ecto_drop
            has_allow "$tok" "$seg_allow" "$EXP_ALLOW" "$HOOK_ALLOW" && continue
            block "\`mix $task\` drops the $env database and all of its data. For the test database run \`MIX_ENV=test mix $task\`; for schema changes use \`mix ecto.rollback\` / \`mix ecto.migrate\`. If the user explicitly asked for this, re-run it prefixed with \`EPG_ALLOW=$tok\`."
            ;;
        esac
      done ;;
    git)
      while [ $# -gt 0 ]; do
        case "$1" in
          -C|-c|--git-dir|--work-tree|--namespace|--config-env|--exec-path|--super-prefix) shift; [ $# -gt 0 ] && shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [ $# -gt 0 ] || return 0
      sub="$1"; shift
      [ "$sub" = push ] || return 0
      for a in "$@"; do
        case "$a" in
          --force-with-lease|--force-with-lease=*|--force-if-includes) ;;
          --force) force=1 ;;
          --*) ;;
          -?*)
            cluster="${a#-}"; cluster="${cluster%%o*}"   # -o takes an argument
            case "$cluster" in *f*) force=1 ;; esac ;;
          +?*) force=1 ;;
        esac
      done
      if [ "${force:-0}" = 1 ]; then
        has_allow force_push "$seg_allow" "$EXP_ALLOW" "$HOOK_ALLOW" && return 0
        block "force push (--force, -f or a +refspec) overwrites remote history. Use \`git push --force-with-lease\` instead. If the user explicitly asked for a force push, re-run it prefixed with \`EPG_ALLOW=force_push\`."
      fi ;;
  esac
  return 0
}

while IFS= read -r SEG; do
  force=0
  set -f
  # shellcheck disable=SC2086 # word splitting is the point
  set -- $SEG
  set +f
  check_segment "$@"
done <<EOF
$SEGMENTS
EOF
exit 0
