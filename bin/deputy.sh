#!/usr/bin/env bash
# deputy.sh — the Deputy runner (queue plumbing). Stateless tooling: it reads and
# mutates BACKLOG.md + .deputy/ under a repo root. No LLM logic lives here.
set -euo pipefail

# ── Root + paths ────────────────────────────────────────────────────────────
resolve_root() {
  if [[ -n "${DEPUTY_ROOT:-}" ]]; then
    printf '%s' "$DEPUTY_ROOT"
  elif root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$root"
  else
    printf '%s' "$PWD"
  fi
}
ROOT="$(resolve_root)"
BACKLOG="$ROOT/BACKLOG.md"
STATE_DIR="$ROOT/.deputy"
LOCK_FILE="$STATE_DIR/lock"
mkdir -p "$STATE_DIR"
[[ -f "$LOCK_FILE" ]] || : > "$LOCK_FILE"

# Yield raw item lines: everything after the legend's closing '-->'. If the file
# has no '-->', every non-blank line is an item.
_each_item() {
  local line seen=0 has_legend=0
  grep -q -- '-->' "$BACKLOG" && has_legend=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$has_legend" -eq 1 && "$seen" -eq 0 ]]; then
      [[ "$line" == *'-->'* ]] && seen=1
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue   # skip blank/whitespace-only
    printf '%s\n' "$line"
  done < "$BACKLOG"
}

# Parse one raw line -> "state|priority|description" (priority may be empty).
_parse_item() {
  local line="$1" state="waiting" prio="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?#!])[[:space:]]+(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;; '@') state=running ;;  '?') state=surfaced ;;
      '#') state=done ;;     '!') state=failed ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  if [[ "$line" =~ ^\[(P[0-2])\]([[:space:]]+(.*))?$ ]]; then
    prio="${BASH_REMATCH[1]}"
    desc="${BASH_REMATCH[3]:-}"
  else
    desc="$line"
  fi
  printf '%s|%s|%s' "$state" "$prio" "$desc"
}

# Build a canonical line from (state, priority, description).
_serialize_item() {
  local state="$1" prio="$2" desc="$3" prefix="" tag="" out=""
  case "$state" in
    waiting) prefix="" ;;  triaging) prefix="~" ;; running) prefix="@" ;;
    surfaced) prefix="?" ;; done) prefix="#" ;;   failed) prefix="!" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  [[ -n "$prio" ]] && tag="[$prio]"
  for part in "$prefix" "$tag" "$desc"; do
    [[ -z "$part" ]] && continue
    [[ -n "$out" ]] && out+=" "
    out+="$part"
  done
  printf '%s' "$out"
}

cmd_list() {
  local raw
  while IFS= read -r raw; do
    _parse_item "$raw"; printf '\n'
  done < <(_each_item)
}

usage() {
  cat <<'EOF'
usage: deputy.sh <command> [args]

commands:
  add "<text>" [--p0|--p1|--p2]   add a waiting item
  list                            print parsed items (state|priority|description)
  status                          counts by state
  pick                            print the highest-priority waiting item (raw line)
  set "<exact line>" <state>      transition an item's state by exact-line match
  claim "<exact line>" [--pid N]  mark an item running and write a claim (serial)
  recover                         revert stale/orphaned claims to waiting
  help                            show this message

states: waiting triaging running surfaced done failed
EOF
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    _parse) _parse_item "${2:-}"; printf '\n'; return 0 ;;
    list) cmd_list; return 0 ;;
    _serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}" && printf '\n' || return 1 ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
