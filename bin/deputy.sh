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
  [[ -f "$BACKLOG" ]] || return 0
  grep -q -- '-->' "$BACKLOG" 2>/dev/null && has_legend=1
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

# Run a function while holding an exclusive lock on LOCK_FILE (short-held).
_with_lock() { ( flock -x 200; "$@" ) 200>"$LOCK_FILE"; }

# Exact whole-line replacement (research.sh flip_line). Atomic via tmpfile+mv.
# Caller holds the lock. Used by upcoming set/claim commands.
_flip_line() {
  local from="$1" to="$2" tmp line; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$from" ]]; then printf '%s\n' "$to"; else printf '%s\n' "$line"; fi
  done < "$BACKLOG" > "$tmp"
  mv "$tmp" "$BACKLOG"
}

# Append a raw line to BACKLOG. Caller holds the lock.
_append_item() { printf '%s\n' "$1" >> "$BACKLOG"; }

# True if any item's parsed description equals $1.
_desc_exists() {
  local want="$1" raw parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    [[ "${parsed#*|*|}" == "$want" ]] && return 0
  done < <(_each_item)
  return 1
}

cmd_add() {
  local text="" prio=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --p0) prio=P0 ;; --p1) prio=P1 ;; --p2) prio=P2 ;;
      --*) printf 'deputy: unknown flag: %s\n' "$1" >&2; return 2 ;;
      *) text="${text}${text:+ }$1" ;;
    esac
    shift
  done
  [[ -n "$text" ]] || { printf 'deputy: add requires text\n' >&2; return 2; }
  _do_add() {
    if _desc_exists "$text"; then
      printf 'deputy: already present: %s\n' "$text"; return 0
    fi
    _append_item "$(_serialize_item waiting "$prio" "$text")"
    printf 'deputy: added: %s\n' "$text"
  }
  _with_lock _do_add
}

cmd_status() {
  local raw state w=0 t=0 r=0 s=0 d=0 f=0 parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting) w=$((w+1)) ;; triaging) t=$((t+1)) ;; running) r=$((r+1)) ;;
      surfaced) s=$((s+1)) ;; done) d=$((d+1)) ;; failed) f=$((f+1)) ;;
    esac
  done < <(_each_item)
  printf 'waiting:  %d\ntriaging: %d\nrunning:  %d\nsurfaced: %d\ndone:     %d\nfailed:   %d\n' \
    "$w" "$t" "$r" "$s" "$d" "$f"
}

# Numeric rank for a priority tag: P0=0 P1=1 P2=2 (none)=3.
_prio_rank() {
  case "$1" in P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; *) echo 3 ;; esac
}

cmd_pick() {
  local raw parsed state prio best_rank=99 best_line="" rank
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    [[ "$state" == "waiting" ]] || continue
    prio="${parsed#*|}"; prio="${prio%%|*}"
    rank="$(_prio_rank "$prio")"
    if (( rank < best_rank )); then          # strict < preserves FIFO on ties
      best_rank="$rank"; best_line="$raw"
    fi
  done < <(_each_item)
  [[ -n "$best_line" ]] && printf '%s\n' "$best_line"
  return 0
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
    add) shift; cmd_add "$@" ;;
    status) cmd_status; return 0 ;;
    pick) cmd_pick; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
