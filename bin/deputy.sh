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
  local from="$1" to="$2" tmp line
  tmp="$(mktemp "$(dirname "$BACKLOG")/.backlog.tmp.XXXXXX")"
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"
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
  # Priority flags: -ui/-u/-i (urgent+important / urgent / important) are aliases
  # for --p0/--p1/--p2. A `--` marker ends flag parsing so a description may begin
  # with a dash (e.g. `deputy add -- "-5% drop alert"`). Last flag wins.
  local text="" prio="" no_more_flags=0
  while [[ $# -gt 0 ]]; do
    if [[ "$no_more_flags" -eq 0 ]]; then
      case "$1" in
        --)         no_more_flags=1; shift; continue ;;
        --p0|-ui)   prio=P0; shift; continue ;;
        --p1|-u)    prio=P1; shift; continue ;;
        --p2|-i)    prio=P2; shift; continue ;;
        -*) printf 'deputy: unknown flag: %s (use -- before a description starting with "-")\n' "$1" >&2; return 2 ;;
      esac
    fi
    text="${text}${text:+ }$1"
    shift
  done
  [[ -n "$text" ]] || { printf 'deputy: add requires text\n' >&2; return 2; }
  text="${text#"${text%%[![:space:]]*}"}"   # left-trim (matches parser's own trim)
  if [[ "$text" =~ ^[~@?#!][[:space:]] ]] || [[ "$text" =~ ^\[P[0-2]\] ]]; then
    printf 'deputy: description may not begin with a status prefix (~@?#!) + space or a [Px] tag: %s\n' "$text" >&2
    return 2
  fi
  if [[ "$text" == *$'\n'* ]]; then
    printf 'deputy: description may not contain a newline\n' >&2
    return 2
  fi
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

_valid_state() {
  case "$1" in waiting|triaging|running|surfaced|done|failed) return 0 ;; *) return 1 ;; esac
}

cmd_set() {
  local from="${1:-}" newstate="${2:-}"
  [[ -n "$from" && -n "$newstate" ]] || { printf 'deputy: set requires "<line>" <state>\n' >&2; return 2; }
  _valid_state "$newstate" || { printf 'deputy: invalid state: %s\n' "$newstate" >&2; return 2; }
  _do_set() {
    grep -qxF -- "$from" "$BACKLOG" || return 1     # exact-line existence
    local parsed prio desc to
    parsed="$(_parse_item "$from")"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    desc="${parsed#*|*|}"
    to="$(_serialize_item "$newstate" "$prio" "$desc")"
    _flip_line "$from" "$to"
  }
  _with_lock _do_set
}

# True if any .deputy/<pid>.claim is owned by a live process.
_live_claim_exists() {
  local f pid
  for f in "$STATE_DIR"/*.claim; do
    [[ -e "$f" ]] || continue
    pid="${f##*/}"; pid="${pid%.claim}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

cmd_claim() {
  local from="" pid="$PPID"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid) [[ $# -gt 1 ]] || { printf 'deputy: --pid requires an argument\n' >&2; return 2; }; pid="$2"; shift 2 ;;
      *) [[ -z "$from" ]] && { from="$1"; shift; } || { printf 'deputy: unexpected arg: %s\n' "$1" >&2; return 2; } ;;
    esac
  done
  [[ -n "$from" ]] || { printf 'deputy: claim requires "<line>"\n' >&2; return 2; }
  [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'deputy: invalid pid: %s\n' "$pid" >&2; return 2; }
  _do_claim() {
    _live_claim_exists && { printf 'deputy: busy (a live claim exists)\n' >&2; return 3; }
    local parsed state
    parsed="$(_parse_item "$from")"; state="${parsed%%|*}"
    [[ "$state" == "waiting" ]] || { printf 'deputy: item is not waiting (%s)\n' "$state" >&2; return 4; }
    grep -qxF -- "$from" "$BACKLOG" || { printf 'deputy: item not found\n' >&2; return 1; }
    local prio desc to
    prio="${parsed#*|}"; prio="${prio%%|*}"; desc="${parsed#*|*|}"
    to="$(_serialize_item running "$prio" "$desc")"
    _flip_line "$from" "$to"
    printf '%s\n' "$to" > "$STATE_DIR/$pid.claim"
  }
  _with_lock _do_claim
}

# Revert a running/triaging line back to waiting (strip the prefix). Caller holds lock.
_revert_to_waiting() {
  local raw="$1" parsed prio desc to
  parsed="$(_parse_item "$raw")"
  prio="${parsed#*|}"; prio="${prio%%|*}"; desc="${parsed#*|*|}"
  to="$(_serialize_item waiting "$prio" "$desc")"
  _flip_line "$raw" "$to"
}

cmd_recover() {
  _do_recover() {
    local f pid line
    # (1) Dead-claim recovery.
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"; pid="${pid%.claim}"
      if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
        line="$(cat "$f")"
        _revert_to_waiting "$line"
        rm -f "$f"
      fi
    done
    # Collect lines still claimed by LIVE pids.
    local -a claimed=()
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"; pid="${pid%.claim}"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        claimed+=("$(cat "$f")")
      fi
    done
    # (2) Orphan recovery: any @/~ item not in a live claim.
    local raw parsed state c found
    while IFS= read -r raw; do
      parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
      [[ "$state" == "running" || "$state" == "triaging" ]] || continue
      found=0
      for c in "${claimed[@]:-}"; do [[ "$c" == "$raw" ]] && { found=1; break; }; done
      [[ "$found" -eq 0 ]] && _revert_to_waiting "$raw"
    done < <(_each_item)
  }
  _with_lock _do_recover
}

usage() {
  cat <<'EOF'
usage: deputy <command> [args]

commands:
  add "<text>" [-ui|-u|-i]        add a waiting item (-ui=P0 -u=P1 -i=P2;
                                  --p0/--p1/--p2 also accepted; use -- before a
                                  description that starts with "-")
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

# Classify a CLI invocation outcome: ok|quota_exhausted|auth_error|hard_error.
# Conservative: an unrecognized non-zero exit is hard_error, never quota_exhausted.
_detect_outcome() {
  local cli="$1" rc="$2" log="$3" content=""
  [[ "$rc" -eq 0 ]] && { printf 'ok\n'; return 0; }
  [[ -f "$log" ]] && content="$(cat "$log")"
  local lc="${content,,}"   # lowercase for case-insensitive matching
  case "$cli" in
    claude) [[ "$lc" == *"hit your limit"* || "$lc" == *"usage limit"* || "$lc" == *"rate limit"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
    gemini) [[ "$lc" == *"resource_exhausted"* || "$lc" == *"429"* || "$lc" == *"quota"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
    codex)  [[ "$lc" == *"usage limit"* || "$lc" == *"rate limit"* || "$lc" == *"quota"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
  esac
  case "$lc" in
    *"not authenticated"*|*"please log in"*|*"/login"*|*"api key"*|*"sign in"*|*"unauthorized"*) \
      printf 'auth_error\n'; return 0 ;;
  esac
  printf 'hard_error\n'
}

# The trivial liveness prompt invocation per CLI.
_probe_cmd() {
  case "$1" in
    claude) claude -p "ping" ;;
    gemini) gemini -p "ping" ;;
    codex)  codex exec "ping" ;;
    *) return 127 ;;
  esac
}

# Probe a CLI: absent | ok | quota_exhausted | auth_error | hard_error.
_probe() {
  local cli="$1"
  command -v "$cli" >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
  local log rc
  log="$(mktemp)"
  set +e
  _probe_cmd "$cli" >"$log" 2>&1
  rc=$?
  set -e
  _detect_outcome "$cli" "$rc" "$log"
  rm -f "$log"
}

# True if $1 appears in the comma-separated list $2.
_in_csv() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Choose a provider for a work kind given available providers (csv).
# Echoes: a provider name | "wait" (claude-bound work, claude down) | "none".
_route() {
  local kind="$1" avail="$2"
  case "$kind" in
    orchestrate|code-complex)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      printf 'wait\n' ;;
    code-simple)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      _in_csv codex  "$avail" && { printf 'codex\n';  return 0; }
      printf 'wait\n' ;;
    review)
      _in_csv gemini "$avail" && { printf 'gemini\n'; return 0; }
      printf 'wait\n' ;;
    *) printf 'none\n'; return 2 ;;
  esac
}

_crontab() { "${DEPUTY_CRONTAB:-crontab}" "$@"; }

# Extract a 24h hour from "resets 11pm" / "resets 3am". Echoes nothing if no match.
_parse_reset_hour() {
  local s="${1,,}" h ampm
  [[ "$s" =~ ([0-9]+)[[:space:]]*(am|pm) ]] || return 0
  h="${BASH_REMATCH[1]}"; ampm="${BASH_REMATCH[2]}"
  if [[ "$ampm" == "pm" && "$h" -lt 12 ]]; then h=$((h + 12))
  elif [[ "$ampm" == "am" && "$h" -eq 12 ]]; then h=0; fi
  printf '%s\n' "$h"
}

# Replace the single deputy cron line with $1 (empty $1 removes it). Marker: a
# trailing "# deputy" comment so we own exactly our line.
_set_cron() {
  local schedule="$1" existing filtered
  existing="$(_crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | grep -v '# deputy' || true)"
  {
    printf '%s\n' "$filtered" | grep -v '^[[:space:]]*$' || true
    [[ -n "$schedule" ]] && printf '%s deputy run  # deputy\n' "$schedule"
  } | _crontab -
}

cmd_cron() {
  case "${1:-}" in
    --ensure)     _set_cron "0 */2 * * *" ;;
    --remove)     _set_cron "" ;;
    --reschedule) local h; h="$(_parse_reset_hour "${2:-}")"
                  if [[ -n "$h" ]]; then _set_cron "0 $h * * *"; else _set_cron "0 */2 * * *"; fi ;;
    *) printf 'deputy: cron needs --ensure|--remove|--reschedule "<text>"\n' >&2; return 2 ;;
  esac
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
    set) shift; cmd_set "$@"; return $? ;;
    claim) shift; cmd_claim "$@"; return $? ;;
    recover) cmd_recover; return 0 ;;
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
    route) shift; _route "${1:-}" "${2:-}"; return $? ;;
    probe) shift; _probe "${1:-}"; return 0 ;;
    cron) shift; cmd_cron "$@"; return $? ;;
    _resethour) shift; _parse_reset_hour "${1:-}"; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
