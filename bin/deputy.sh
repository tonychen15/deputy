#!/usr/bin/env bash
# deputy.sh — the Deputy runner (queue plumbing). Stateless tooling: it reads and
# mutates BACKLOG.md + .deputy/ under a repo root. No LLM logic lives here.
set -euo pipefail

# Ensure agent CLIs are found under cron's minimal PATH (idempotent).
# Set DEPUTY_NO_PATH_FIX=1 to suppress (e.g. in tests that supply mock CLIs).
if [[ "${DEPUTY_NO_PATH_FIX:-0}" != "1" ]]; then
  for _d in "$HOME/.local/bin" "$HOME/.local/share/fnm/aliases/default/bin"; do
    case ":$PATH:" in *":$_d:"*) ;; *) [[ -n "$_d" ]] && PATH="$_d:$PATH" ;; esac
  done
  export PATH; unset _d
fi

# Deputy install dir (where hooks/ lives). Allow env override for tests.
# Resolve symlinks so this works when deputy is installed as a symlink in PATH.
SRC_DIR="${SRC_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/.." && pwd)}"

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

# Yield raw item lines: everything after the "## Items" heading. Falls back to
# after a legacy "<!-- ... -->" legend, else every non-blank line. Blank lines
# are skipped for iteration (but left intact in the file).
_each_item() {
  local line seen=0 mode=none
  [[ -f "$BACKLOG" ]] || return 0
  if grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null; then mode=items
  elif grep -q -- '-->' "$BACKLOG" 2>/dev/null; then mode=comment
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$seen" -eq 0 && "$mode" != "none" ]]; then
      if [[ "$mode" == "items" && "$line" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]]; then seen=1; fi
      [[ "$mode" == "comment" && "$line" == *'-->'* ]] && seen=1
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue
    printf '%s\n' "$line"
  done < "$BACKLOG"
}

# Parse one raw line -> "state|priority|id|description". Lenient: accepts an optional
# space after the status prefix (so both `#[P0] x` and `# [P0] x` parse the same).
# [#N] is recognized ONLY in the tag zone (immediately after status + optional [Pn]),
# never inside the description body. Either order [Pn][#N] or [#N][Pn] is accepted.
_parse_item() {
  local line="$1" state="waiting" prio="" id="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?#!%=^>])[[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;;  '@') state=running ;;    '?') state=surfaced ;;
      '#') state=done ;;      '!') state=failed ;;
      '%') state=cancelled ;; '=') state=duplicate ;; '^') state=paused ;;
      '>') state=deferred ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  # Tag zone: consume [Pn] and [#N] in either order (both optional, at most one each).
  local consumed=1
  while [[ "$consumed" -eq 1 ]]; do
    consumed=0
    if [[ -z "$prio" && "$line" =~ ^\[(P[0-2])\][[:space:]]*(.*) ]]; then
      prio="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; consumed=1
    fi
    if [[ -z "$id" && "$line" =~ ^\[#([0-9]+)\][[:space:]]*(.*) ]]; then
      id="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; consumed=1
    fi
  done
  desc="$line"
  printf '%s|%s|%s|%s' "$state" "$prio" "$id" "$desc"
}

# Build a canonical line from (state, priority, id, description).
# Canonical order: <status>[Pn][#N] description
# The status symbol directly abuts what follows (no space): `#[P0][#3] x`, `[#7] x`, `Plain`.
_serialize_item() {
  local state="$1" prio="$2" id="$3" desc="$4" prefix="" body=""
  case "$state" in
    waiting)   prefix="" ;;  triaging)  prefix="~" ;; running)   prefix="@" ;;
    surfaced)  prefix="?" ;; done)      prefix="#" ;; failed)    prefix="!" ;;
    cancelled) prefix="%" ;; duplicate) prefix="=" ;; paused)    prefix="^" ;;
    deferred)  prefix=">" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  body=""
  [[ -n "$prio" ]] && body="${body}[${prio}]"
  [[ -n "$id"   ]] && body="${body}[#${id}]"
  if [[ -n "$body" ]]; then
    [[ -n "$desc" ]] && body="${body} ${desc}"
  else
    body="$desc"
  fi
  printf '%s%s' "$prefix" "$body"
}

cmd_list() {
  _with_lock _allocate_ids
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
  _regroup_backlog
}

# Append a raw line preceded by a blank line so items stay blank-separated.
# Caller holds the lock.
_append_item() {
  printf '\n%s\n' "$1" >> "$BACKLOG"
  _regroup_backlog
}

# Rewrite BACKLOG.md with items grouped by state: waiting first, active
# (triaging/running/surfaced/paused) next, terminal (done/failed/cancelled/
# duplicate) last. Each non-empty group is preceded by a blank line; items
# within a group are consecutive. No-ops if no '## Items' heading is found.
# Caller holds the lock.
_regroup_backlog() {
  grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null || return 0
  local line tmp
  local -a waiting_items=() active_items=() deferred_items=() terminal_items=()

  tmp="$(mktemp "$(dirname "$BACKLOG")/.backlog.tmp.XXXXXX")"
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"

  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >> "$tmp"
    if [[ "$line" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]]; then break; fi
  done < "$BACKLOG"

  local raw parsed state
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    case "$state" in
      waiting)                              waiting_items+=("$raw") ;;
      triaging|running|surfaced|paused)     active_items+=("$raw") ;;
      deferred)                             deferred_items+=("$raw") ;;
      done|failed|cancelled|duplicate)      terminal_items+=("$raw") ;;
    esac
  done < <(_each_item)

  [[ ${#waiting_items[@]} -gt 0 ]]   && { printf '\n' >> "$tmp"; printf '%s\n' "${waiting_items[@]}"   >> "$tmp"; }
  [[ ${#active_items[@]} -gt 0 ]]    && { printf '\n' >> "$tmp"; printf '%s\n' "${active_items[@]}"    >> "$tmp"; }
  [[ ${#deferred_items[@]} -gt 0 ]]  && { printf '\n' >> "$tmp"; printf '%s\n' "${deferred_items[@]}"  >> "$tmp"; }
  [[ ${#terminal_items[@]} -gt 0 ]]  && { printf '\n' >> "$tmp"; printf '%s\n' "${terminal_items[@]}"  >> "$tmp"; }

  mv "$tmp" "$BACKLOG"
}

# Assign sequential [#N] IDs to any item that lacks one. Lock-held, idempotent,
# append-only: existing IDs are never changed. Writes back atomically only if
# something changed (so status/list calls are pure no-op after the first pass).
# Caller holds the lock.
_allocate_ids() {
  [[ -f "$BACKLOG" ]] || return 0
  # Pass 1: find max existing ID across ALL items (including done/failed/etc.)
  local max_id=0 raw parsed _ai_id
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    _ai_id="${parsed#*|}"; _ai_id="${_ai_id#*|}"; _ai_id="${_ai_id%%|*}"  # third field
    if [[ "$_ai_id" =~ ^[0-9]+$ && "$_ai_id" -gt "$max_id" ]]; then max_id="$_ai_id"; fi
  done < <(_each_item)

  # Pass 2: rewrite only items lacking an ID. Track whether anything changed.
  local changed=0 next_id=$(( max_id + 1 ))
  local tmp
  tmp="$(mktemp "$(dirname "$BACKLOG")/.backlog.tmp.XXXXXX")"
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"

  # Rewrite the whole file, replacing un-id'd item lines in-place.
  local _ai_line _ai_seen=0 _ai_mode=none
  if grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null; then _ai_mode=items
  elif grep -q -- '-->' "$BACKLOG" 2>/dev/null; then _ai_mode=comment
  fi
  while IFS= read -r _ai_line || [[ -n "$_ai_line" ]]; do
    # Copy header lines verbatim until the items section starts
    if [[ "$_ai_seen" -eq 0 && "$_ai_mode" != "none" ]]; then
      printf '%s\n' "$_ai_line" >> "$tmp"
      if [[ "$_ai_mode" == "items" && "$_ai_line" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]]; then _ai_seen=1; fi
      [[ "$_ai_mode" == "comment" && "$_ai_line" == *'-->'* ]] && _ai_seen=1
      continue
    fi
    # Preserve blank lines
    if [[ -z "${_ai_line//[[:space:]]/}" ]]; then
      printf '%s\n' "$_ai_line" >> "$tmp"; continue
    fi
    # Check if this item line needs an ID
    parsed="$(_parse_item "$_ai_line")"
    _ai_id="${parsed#*|}"; _ai_id="${_ai_id#*|}"; _ai_id="${_ai_id%%|*}"
    if [[ -z "$_ai_id" ]]; then
      local _ai_state="${parsed%%|*}"
      local _ai_prio="${parsed#*|}"; _ai_prio="${_ai_prio%%|*}"
      local _ai_desc_rest="${parsed#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"
      local _ai_new_line
      _ai_new_line="$(_serialize_item "$_ai_state" "$_ai_prio" "$next_id" "$_ai_desc_rest")"
      printf '%s\n' "$_ai_new_line" >> "$tmp"
      next_id=$(( next_id + 1 ))
      changed=1
    else
      printf '%s\n' "$_ai_line" >> "$tmp"
    fi
  done < "$BACKLOG"

  if [[ "$changed" -eq 1 ]]; then
    mv "$tmp" "$BACKLOG"
    _regroup_backlog
  else
    rm -f "$tmp"
  fi
}

# True if any item's parsed description equals $1.
_desc_exists() {
  local want="$1" raw parsed _rest
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    # Extract 4th field (description): strip state|prio|id|
    _rest="${parsed#*|}"; _rest="${_rest#*|}"; _rest="${_rest#*|}"
    [[ "$_rest" == "$want" ]] && return 0
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
  local _pfx="${text:0:1}"
  if [[ "$_pfx" == '~' || "$_pfx" == '@' || "$_pfx" == '?' || "$_pfx" == '#' || \
        "$_pfx" == '!' || "$_pfx" == '%' || "$_pfx" == '=' || "$_pfx" == '^' || \
        "$_pfx" == '>' ]] || [[ "$text" =~ ^\[P[0-2]\] ]]; then
    printf 'deputy: description may not begin with a status prefix (~@?#!%%=^>) or a [Px] tag: %s\n' "$text" >&2
    return 2
  fi
  if [[ "$text" == *$'\n'* ]]; then
    printf 'deputy: description may not contain a newline\n' >&2
    return 2
  fi
  _do_add() {
    _allocate_ids
    if _desc_exists "$text"; then
      printf 'deputy: already present: %s\n' "$text"; return 0
    fi
    _append_item "$(_serialize_item waiting "$prio" "" "$text")"
    printf 'deputy: added: %s\n' "$text"
  }
  _with_lock _do_add
  # Trigger execution immediately if nothing is running and work is available.
  # Set DEPUTY_NO_AUTORUN=1 to suppress (used in tests that exercise add in isolation).
  if [[ "${DEPUTY_NO_AUTORUN:-0}" != "1" ]] && ! _live_claim_exists && [[ -n "$(cmd_pick)" ]]; then
    _autorun
  fi
}

# Kick off a background drain so 'deputy add' returns immediately (research.sh model).
# Tests override via DEPUTY_AUTORUN_CMD.
_autorun() {
  if [[ -n "${DEPUTY_AUTORUN_CMD:-}" ]]; then "$DEPUTY_AUTORUN_CMD"; return 0; fi
  local bin; bin="$(command -v deputy 2>/dev/null || readlink -f "${BASH_SOURCE[0]}")"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  ( "$bin" run >> "$STATE_DIR/run.log" 2>&1 & ) 2>/dev/null || true
}

cmd_status() {
  _with_lock _allocate_ids
  local raw state w=0 t=0 r=0 s=0 d=0 f=0 c=0 u=0 p=0 df=0 parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting) w=$((w+1)) ;; triaging) t=$((t+1)) ;; running)    r=$((r+1)) ;;
      surfaced) s=$((s+1)) ;; done) d=$((d+1)) ;;    failed)     f=$((f+1)) ;;
      cancelled) c=$((c+1)) ;; duplicate) u=$((u+1)) ;; paused)  p=$((p+1)) ;;
      deferred) df=$((df+1)) ;;
    esac
  done < <(_each_item)
  printf 'waiting:  %d\ntriaging: %d\nrunning:  %d\nsurfaced: %d\ndone:     %d\nfailed:   %d\ncancelled: %d\nduplicate: %d\npaused:   %d\ndeferred: %d\n' \
    "$w" "$t" "$r" "$s" "$d" "$f" "$c" "$u" "$p" "$df"
}

# Numeric rank for a priority tag: P0=0 P1=1 P2=2 (none)=3.
_prio_rank() {
  case "$1" in P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; *) echo 3 ;; esac
}

cmd_pick() {
  _with_lock _allocate_ids
  local raw parsed state prio best_rank=99 best_line="" rank
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    [[ "$state" == "waiting" || "$state" == "paused" ]] || continue
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
  case "$1" in waiting|triaging|running|surfaced|done|failed|cancelled|duplicate|paused|deferred) return 0 ;; *) return 1 ;; esac
}

# ── Notifications ─────────────────────────────────────────────────────────────
# Fires when an item reaches surfaced/done/failed/cancelled/duplicate.
# Config keys (.deputy/config):
#   notify=desktop,push,email    comma-separated list of enabled channels
#   notify_push_url=<url>        ntfy.sh-compatible URL (required for push channel)
#   notify_email=<address>       recipient address (required for email channel)
# Any channel whose prerequisite is absent is silently skipped.

_notify_label() {
  case "$1" in
    surfaced)  printf 'Needs Input' ;;
    done)      printf 'Done' ;;
    failed)    printf 'Failed' ;;
    cancelled) printf 'Cancelled' ;;
    duplicate) printf 'Duplicate' ;;
    *)         printf '%s' "$1" ;;
  esac
}

_notify_desktop() {
  local title="$1" body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" 2>/dev/null || true
  elif command -v osascript >/dev/null 2>&1; then
    # Pass via env vars to avoid AppleScript injection from special chars in description.
    DEPUTY_NOTIF_TITLE="$title" DEPUTY_NOTIF_BODY="$body" \
      osascript -e 'display notification (system attribute "DEPUTY_NOTIF_BODY") with title (system attribute "DEPUTY_NOTIF_TITLE")' \
      2>/dev/null || true
  fi
}

_notify_push() {
  local title="$1" body="$2" url
  url="$(_config_get notify_push_url)"
  [[ -n "$url" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -s --max-time 3 -H "Title: $title" -d "$body" "$url" >/dev/null 2>&1 || true
}

_notify_email() {
  local title="$1" body="$2" addr
  addr="$(_config_get notify_email)"
  [[ -n "$addr" ]] || return 0
  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$title" "$addr" 2>/dev/null || true
  elif command -v sendmail >/dev/null 2>&1; then
    printf 'To: %s\nSubject: %s\n\n%s\n' "$addr" "$title" "$body" | sendmail "$addr" 2>/dev/null || true
  fi
}

# Fire notifications for terminal/attention states. Silently no-ops for other states
# or when no channels are configured.
_notify() {
  local state="$1" desc="$2"
  case "$state" in surfaced|done|failed|cancelled|duplicate) ;; *) return 0 ;; esac
  local channels; channels="$(_config_get notify)"
  [[ -n "$channels" ]] || return 0
  local label; label="$(_notify_label "$state")"
  local title="Deputy: $label"
  local ch
  while IFS= read -r ch; do
    ch="${ch#"${ch%%[![:space:]]*}"}"; ch="${ch%"${ch##*[![:space:]]}"}"
    case "$ch" in
      desktop) _notify_desktop "$title" "$desc" ;;
      push)    _notify_push    "$title" "$desc" ;;
      email)   _notify_email   "$title" "$desc" ;;
    esac
  done < <(printf '%s\n' "$channels" | tr ',' '\n')
}

cmd_set() {
  local from="${1:-}" newstate="${2:-}"
  [[ -n "$from" && -n "$newstate" ]] || { printf 'deputy: set requires "<line>" <state>\n' >&2; return 2; }
  _valid_state "$newstate" || { printf 'deputy: invalid state: %s\n' "$newstate" >&2; return 2; }
  _do_set() {
    grep -qxF -- "$from" "$BACKLOG" || return 1     # exact-line existence
    local parsed prio desc to _id_rest _id
    parsed="$(_parse_item "$from")"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    _id_rest="${parsed#*|}"; _id_rest="${_id_rest#*|}"; _id="${_id_rest%%|*}"
    desc="${_id_rest#*|}"
    to="$(_serialize_item "$newstate" "$prio" "$_id" "$desc")"
    _flip_line "$from" "$to"
  }
  local _set_rc=0
  _with_lock _do_set || _set_rc=$?
  if [[ "$_set_rc" -eq 0 ]]; then
    local _parsed _desc _id_rest2
    _parsed="$(_parse_item "$from")"
    _id_rest2="${_parsed#*|}"; _id_rest2="${_id_rest2#*|}"; _desc="${_id_rest2#*|}"
    # Background by default so slow channels (e.g. push/curl) don't block the CLI.
    # Set DEPUTY_NOTIFY_SYNC=1 to run synchronously (used in tests).
    if [[ "${DEPUTY_NOTIFY_SYNC:-0}" == "1" ]]; then
      _notify "$newstate" "$_desc" >/dev/null 2>&1 || true
    else
      _notify "$newstate" "$_desc" >/dev/null 2>&1 &
    fi
  fi
  return "$_set_rc"
}

# Get the start-time of a pid using ps lstart (portable; empty if unavailable).
_pid_start_time() {
  local pid="$1"
  ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true
}

# True if any .deputy/<pid>.claim is owned by a LIVE process with matching start-time.
# Claim file format:
#   Line 1: the running item line
#   Line 2: the PID start-time (optional; if present, must match to count as live)
# A claim is live only if: pid exists (kill -0) AND (no start-time recorded OR start-time matches).
_live_claim_exists() {
  local f pid
  for f in "$STATE_DIR"/*.claim; do
    [[ -e "$f" ]] || continue
    pid="${f##*/}"; pid="${pid%.claim}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    # PID is alive; validate start-time if recorded in claim.
    local recorded_start actual_start
    recorded_start="$(sed -n '2p' "$f" 2>/dev/null || true)"
    if [[ -n "$recorded_start" ]]; then
      actual_start="$(_pid_start_time "$pid")"
      [[ "$actual_start" == "$recorded_start" ]] || continue  # start-time mismatch → stale
    fi
    return 0
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
    [[ "$state" == "waiting" || "$state" == "paused" ]] || { printf 'deputy: item is not waiting/paused (%s)\n' "$state" >&2; return 4; }
    grep -qxF -- "$from" "$BACKLOG" || { printf 'deputy: item not found\n' >&2; return 1; }
    local prio desc to _cid_rest _cid
    prio="${parsed#*|}"; prio="${prio%%|*}"
    _cid_rest="${parsed#*|}"; _cid_rest="${_cid_rest#*|}"; _cid="${_cid_rest%%|*}"
    desc="${_cid_rest#*|}"
    to="$(_serialize_item running "$prio" "$_cid" "$desc")"
    _flip_line "$from" "$to"
    # Write claim file: line 1 = running item line; line 2 = PID start-time for liveness validation.
    local _claim_start; _claim_start="$(_pid_start_time "$pid")"
    printf '%s\n%s\n' "$to" "$_claim_start" > "$STATE_DIR/$pid.claim"
  }
  _with_lock _do_claim
}

# Revert a running/triaging line back to waiting (strip the prefix). Caller holds lock.
_revert_to_waiting() {
  local raw="$1" parsed prio desc to _rid_rest _rid
  parsed="$(_parse_item "$raw")"
  prio="${parsed#*|}"; prio="${prio%%|*}"
  _rid_rest="${parsed#*|}"; _rid_rest="${_rid_rest#*|}"; _rid="${_rid_rest%%|*}"
  desc="${_rid_rest#*|}"
  to="$(_serialize_item waiting "$prio" "$_rid" "$desc")"
  _flip_line "$raw" "$to"
}

cmd_recover() {
  _do_recover() {
    local f pid line recorded_start actual_start
    # (1) Dead-claim recovery: a claim is dead if the pid is gone OR start-time mismatches.
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"; pid="${pid%.claim}"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      local _claim_dead=0
      if ! kill -0 "$pid" 2>/dev/null; then
        _claim_dead=1
      else
        # PID alive — check start-time (line 2 of claim file).
        recorded_start="$(sed -n '2p' "$f" 2>/dev/null || true)"
        if [[ -n "$recorded_start" ]]; then
          actual_start="$(_pid_start_time "$pid")"
          [[ "$actual_start" != "$recorded_start" ]] && _claim_dead=1
        fi
      fi
      if [[ "$_claim_dead" -eq 1 ]]; then
        # Read item line from line 1 of claim file.
        line="$(sed -n '1p' "$f" 2>/dev/null || true)"
        [[ -n "$line" ]] && _revert_to_waiting "$line" || true
        rm -f "$f"
      fi
    done
    # Collect item lines still claimed by LIVE pids (with matching start-time).
    local -a claimed=()
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"; pid="${pid%.claim}"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -0 "$pid" 2>/dev/null || continue
      recorded_start="$(sed -n '2p' "$f" 2>/dev/null || true)"
      if [[ -n "$recorded_start" ]]; then
        actual_start="$(_pid_start_time "$pid")"
        [[ "$actual_start" == "$recorded_start" ]] || continue
      fi
      # Claim is live; record item line (line 1 of claim file).
      claimed+=("$(sed -n '1p' "$f" 2>/dev/null || true)")
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

cmd_review() {
  _with_lock _allocate_ids
  local any=0 raw parsed state desc f _rv_rest
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    [[ "$state" == "surfaced" ]] || continue
    _rv_rest="${parsed#*|}"; _rv_rest="${_rv_rest#*|}"; desc="${_rv_rest#*|}"
    printf '? %s\n' "$desc"; any=1
  done < <(_each_item)
  shopt -s nullglob
  for f in "$STATE_DIR"/*.questions.md; do
    printf '\n--- %s ---\n' "$(basename "$f")"
    cat "$f"
  done
  shopt -u nullglob
  if [[ "$any" -eq 0 ]]; then printf 'deputy: nothing surfaced.\n'; fi
  printf '\n'
  cmd_status
}

usage() {
  cat <<'EOF'
usage: deputy <command> [args]

commands:
  add "<text>" [-ui|-u|-i]        add a waiting item and run it immediately if idle
                                  (-ui=P0 -u=P1 -i=P2; --p0/--p1/--p2 also accepted;
                                  use -- before a description that starts with "-";
                                  set DEPUTY_NO_AUTORUN=1 to enqueue without running)
  list                            print parsed items (state|priority|id|description)
  status                          counts by state
  run [<id>] [--once]             work the backlog: claim the top item, run the orchestrator
                                  if <id> given (integer; '#7' also accepted), run that
                                  specific item bypassing priority order (targeted, one item only)
  pick                            print the highest-priority waiting item (raw line)
  set "<exact line>" <state>      transition an item's state by exact-line match
  claim "<exact line>" [--pid N]  mark an item running and write a claim (serial)
  recover                         revert stale/orphaned claims to waiting
  probe <cli>                     check a provider's availability
  route <kind> <avail-csv>        choose a provider (orchestrate|code-complex|code-simple|review)
  cron --ensure|--remove|--reschedule "<text>"   manage the safety-net schedule
  detect <cli> <rc> <log>         (internal) classify a CLI outcome
  review                          show surfaced items, their questions, and the digest
  clean [--dry-run] [--state <state>]
                                  remove items of <state> (default: waiting = untouched items)
                                  cleanable states: waiting, done, failed, cancelled, duplicate, deferred
                                  refuses running, triaging, surfaced, paused (active/checkpointed/awaiting)
  reflect [--apply]               re-triage report: learnings, untagged items, reprioritization list,
                                  surfaced items, duplicate candidates; --apply writes .deputy/learnings.md
  help                            show this message

config keys (.deputy/config):
  max_items=N                     items started per run cycle (default 0 = unlimited)
  notify=desktop,push,email       channels for item-surfaced/finished notifications
  notify_push_url=<url>           ntfy.sh-compatible push URL (required for push)
  notify_email=<address>          recipient address (required for email)
states: waiting triaging running surfaced done failed cancelled duplicate paused deferred
symbols: (none)=waiting ~=triaging @=running ?=surfaced #=done !=failed %=cancelled ==duplicate ^=paused >=deferred
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
    *"not authenticated"*|*"not logged in"*|*"please log in"*|*"/login"*|*"api key"*|*"sign in"*|*"unauthorized"*) \
      printf 'auth_error\n'; return 0 ;;
  esac
  printf 'hard_error\n'
}

# The trivial liveness prompt invocation per CLI.
_probe_cmd() {
  case "$1" in
    claude) claude -p "ping" ;;
    gemini) gemini -p "ping" ;;
    codex)  codex login status ;;
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

# True (0) if this repo has opted in to the autonomous cron heartbeat.
_cron_enabled() { [[ -f "$STATE_DIR/cron.enabled" ]]; }

# Extract seconds-until-reset from provider error text. Echoes integer seconds or nothing.
# Handles Gemini: "retry after: Ns", "retry-after: N", "retryDelay: Ns" (JSON).
# Handles Codex:  "retry after N seconds", "try again in N minutes/seconds".
_parse_reset_secs() {
  local s="${1,,}"
  # Gemini/Codex: "retry after: Ns" or "retry-after: N" (colon form, with or without unit)
  if [[ "$s" =~ retry[[:space:]]*-?[[:space:]]*after[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  # Gemini JSON: "retryDelay":"3600s" or retryDelay: 3600s
  if [[ "$s" =~ retrydelay[^0-9]*([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  # Codex: "retry after N seconds" (no colon — distinct from colon form above)
  if [[ "$s" =~ retry[[:space:]]+after[[:space:]]+([0-9]+)[[:space:]]*(s|sec|second) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  # Codex: "try again in N minutes" or "try again in N seconds"
  if [[ "$s" =~ try[[:space:]]+again[[:space:]]+in[[:space:]]+([0-9]+)[[:space:]]*(m|min|minute) ]]; then
    printf '%s\n' "$(( BASH_REMATCH[1] * 60 ))"; return 0
  fi
  if [[ "$s" =~ try[[:space:]]+again[[:space:]]+in[[:space:]]+([0-9]+)[[:space:]]*(s|sec|second) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
}

# Extract a 24h hour from reset hint text. Echoes nothing if no match.
# Handles:
#   - Gemini/Codex seconds patterns via _parse_reset_secs → future cron hour
#   - ISO 8601 timestamps (Gemini quota reset): "2025-01-15T23:00:00Z" → hour, rounded up if mins>0
#   - Claude am/pm: "resets 11pm" / "resets 3am"
_parse_reset_hour() {
  local s="${1,,}" h ampm secs
  # Seconds-based patterns (Gemini/Codex)
  secs="$(_parse_reset_secs "$s")"
  if [[ -n "$secs" ]]; then
    local cur_h cur_m
    cur_h="${DEPUTY_NOW_HOUR:-$(date +%H:%M)}"
    cur_m="${cur_h#*:}"; cur_h="${cur_h%%:*}"
    # ceil(secs/3600) hours from now, modulo 24
    h=$(( (10#$cur_h * 60 + 10#$cur_m + (secs + 59) / 60 + 59) / 60 % 24 ))
    printf '%s\n' "$h"; return 0
  fi
  # ISO 8601 timestamp (Gemini quota reset): extract hour, round up if mins > 0
  local _iso_re='[0-9]{4}-[0-9]{2}-[0-9]{2}[tT]([0-9]{2}):([0-9]{2}):[0-9]{2}'
  if [[ "$s" =~ $_iso_re ]]; then
    h="$(( 10#${BASH_REMATCH[1]} ))"
    [[ "$(( 10#${BASH_REMATCH[2]} ))" -gt 0 ]] && h=$(( (h + 1) % 24 ))
    printf '%s\n' "$h"; return 0
  fi
  # Claude-style am/pm
  [[ "$s" =~ ([0-9]+)[[:space:]]*(am|pm) ]] || return 0
  h="${BASH_REMATCH[1]}"; ampm="${BASH_REMATCH[2]}"
  if [[ "$ampm" == "pm" && "$h" -lt 12 ]]; then h=$((h + 12))
  elif [[ "$ampm" == "am" && "$h" -eq 12 ]]; then h=0; fi
  printf '%s\n' "$h"
}

# Replace this repo's deputy cron line with the given schedule (empty = remove).
# Uses a per-repo delimited marker "# deputy[<ABS_ROOT>]" so multiple repos coexist
# and prefix collisions are impossible (the [ ] delimiters prevent /x/repo matching
# /x/repo-two).
_set_cron() {
  local schedule="$1" root bin marker existing filtered root_q bin_q
  root="$(resolve_root)"
  bin="$(command -v deputy 2>/dev/null || readlink -f "${BASH_SOURCE[0]}")"
  marker="# deputy[$root]"
  # Single-quote-safe versions (replace ' with '\'' for embedding in single-quoted shell words).
  root_q="${root//\'/\'\\\'\'}"
  bin_q="${bin//\'/\'\\\'\'}"
  existing="$(_crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | grep -vF "$marker" || true)"
  {
    printf '%s\n' "$filtered" | grep -v '^[[:space:]]*$' || true
    if [[ -n "$schedule" ]]; then
      printf "%s cd '%s' && '%s' run >> '%s/.deputy/cron.log' 2>&1  %s\n" \
        "$schedule" "$root_q" "$bin_q" "$root_q" "$marker"
    fi
  } | _crontab -
}

cmd_cron() {
  case "${1:-}" in
    --ensure)
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      : > "$STATE_DIR/cron.enabled"
      # Read heartbeat_mins from config; validate integer in 1–59; default 10.
      local _hm; _hm="$(_config_get heartbeat_mins)"
      if [[ "$_hm" =~ ^[0-9]+$ ]] && [[ "$_hm" -ge 1 ]] && [[ "$_hm" -le 59 ]]; then
        _set_cron "*/$_hm * * * *"
      else
        _set_cron "*/10 * * * *"
      fi
      ;;
    --remove)     rm -f "$STATE_DIR/cron.enabled" 2>/dev/null || true; _set_cron "" ;;
    --reschedule) local h; h="$(_parse_reset_hour "${2:-}")"
                  if [[ -n "$h" ]]; then _set_cron "0 $h * * *"
                  else _set_cron "0 */2 * * *"; fi ;;
    *) printf 'deputy: cron needs --ensure|--remove|--reschedule "<text>"\n' >&2; return 2 ;;
  esac
}

# Read a single key from .deputy/config (KEY=VALUE). Echoes the value or empty.
_config_get() {
  local key="$1" cfg="$STATE_DIR/config" line k v
  [[ -f "$cfg" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    if [[ "$k" == "$key" ]]; then printf '%s\n' "$v"; return 0; fi
  done < "$cfg"
}

# True (0) if any path (newline-separated, from $1) matches a glob in
# .deputy/protected. Deterministic; used as the pre-commit gate.
_protected_violation() {
  local input="$1" prot="$STATE_DIR/protected" path glob
  [[ -f "$prot" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    while IFS= read -r glob || [[ -n "$glob" ]]; do
      [[ -n "$glob" && "$glob" != \#* ]] || continue
      case "$path" in $glob) return 0 ;; esac
    done < "$prot"
  done <<< "$input"
  return 1
}

_wt_path() { printf '%s' "${DEPUTY_WT:-$STATE_DIR/wt}"; }

# Create the execution worktree on branch deputy/<slug>. New branch from HEAD, or
# attach to it if it already exists (resume / forward-recovery).
_wt_create() {
  local slug="$1"
  [[ "$slug" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    printf 'deputy: invalid slug (alphanumeric, dash, underscore only): %s\n' "$slug" >&2; return 2
  }
  local wt branch
  wt="$(_wt_path)"; branch="deputy/$slug"
  _do_wt_create() {
    git -C "$ROOT" worktree prune 2>/dev/null || true
    [[ -e "$wt" ]] && git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null || true
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$ROOT" worktree add "$wt" "$branch" >/dev/null
    else
      git -C "$ROOT" worktree add "$wt" -b "$branch" >/dev/null
    fi
  }
  _with_lock _do_wt_create
}

_wt_remove() {
  _do_wt_remove() {
    local wt; wt="$(_wt_path)"
    [[ -e "$wt" ]] && git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$ROOT" worktree prune 2>/dev/null || true
  }
  _with_lock _do_wt_remove
}

# Availability csv: $DEPUTY_AVAIL override (tests), else probe the three CLIs.
_availability() {
  if [[ -n "${DEPUTY_AVAIL:-}" ]]; then printf '%s\n' "$DEPUTY_AVAIL"; return 0; fi
  local c avail=""
  for c in claude gemini codex; do [[ "$(_probe "$c")" == ok ]] && avail+="${avail:+,}$c"; done
  printf '%s\n' "$avail"
}

# Write a per-spawn Claude settings file registering the guardrail PreToolUse hook
# (absolute hook path), and echo its path. SRC_DIR is the deputy install dir.
# The raw absolute path is passed to jq for JSON encoding only — no shell-quoting
# via printf %q (which would double-encode when Claude Code invokes the hook via
# execFile without a shell).
_guardrail_settings_path() {
  local hook="$SRC_DIR/hooks/guardrail.sh"
  local f="$STATE_DIR/guardrail-settings.json"
  local matcher="Bash|Edit|Write|MultiEdit|NotebookEdit"
  mkdir -p "$STATE_DIR"
  jq -n --arg hook "$hook" --arg matcher "$matcher" \
    '{"hooks":{"PreToolUse":[{"matcher":$matcher,
      "hooks":[{"type":"command","command":$hook}]}]}}' > "$f"
  printf '%s' "$f"
}

# Spawn the orchestrator for a claimed item. If DEPUTY_ORCHESTRATOR_CMD is set
# (tests / custom drivers), call it as `<cmd> <item-line> <provider>`. Otherwise
# build a headless prompt that runs the deputy orchestrator skill on this one item.
_spawn_orchestrator() {
  local item="$1" provider="$2"
  if [[ -n "${DEPUTY_ORCHESTRATOR_CMD:-}" ]]; then
    "$DEPUTY_ORCHESTRATOR_CMD" "$item" "$provider"
    return $?
  fi
  local prompt
  prompt="You are the Deputy orchestrator — use the 'deputy' skill. Work this ONE claimed backlog item end-to-end per the skill's loop, then stop.
Repo root: $ROOT
Item (the exact current BACKLOG.md line — pass it verbatim to 'deputy set'): $item
Provider for coding: $provider
Use the 'deputy' CLI for ALL state changes (deputy set / wt-create / wt-remove / config / protected); never edit BACKLOG.md directly. Honor the protected-path gate and run an xReview (gemini) before each commit. The item MUST end marked done/failed/surfaced/cancelled/duplicate via 'deputy set \"<line>\" <state>'."
  local gset; gset="$(_guardrail_settings_path)"
  DEPUTY_GUARDED=1 DEPUTY_WT="$(_wt_path)" DEPUTY_ROOT="$ROOT" \
    claude -p "$prompt" --model claude-sonnet-4-6 \
      --allowedTools "Bash,Edit,Write,Read,Glob,Grep" \
      --settings "$gset"
}

# One tick: claim the top item and hand it to the orchestrator. --once = no loop.
# If an integer <id> is given (deputy run <id> or deputy run '#<id>'), run that
# specific item bypassing priority, then return (targeted = one item only).
cmd_run() {
  local once=0 target_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      '#'*) target_id="${1#'#'}"; shift ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          target_id="$1"; shift
        elif [[ -n "$1" ]]; then
          printf 'deputy: run: id must be an integer (got: %s)\n' "$1" >&2; return 2
        else
          shift
        fi
        ;;
    esac
  done

  # Validate target_id: strip leading # and verify integer
  if [[ -n "$target_id" ]]; then
    target_id="${target_id#'#'}"
    if [[ ! "$target_id" =~ ^[0-9]+$ ]]; then
      printf 'deputy: run: id must be an integer (got: %s)\n' "$target_id" >&2; return 2
    fi
  fi

  cmd_recover >/dev/null 2>&1 || true
  if _live_claim_exists; then return 0; fi
  # Always-on model: do NOT remove the cron line while running. The line persists;
  # each tick is state-aware (skip when live, recover orphans, etc.).
  local cap; cap="$(_config_get max_items)"; cap="${cap:-0}"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
  local processed=0 item avail decision running_line log rc outcome reset

  # ── Targeted run: find item by id and run it (bypasses priority) ─────────────
  if [[ -n "$target_id" ]]; then
    _with_lock _allocate_ids
    local found_line="" found_state="" _tr_raw _tr_p _tr_id
    while IFS= read -r _tr_raw; do
      _tr_p="$(_parse_item "$_tr_raw")"
      _tr_id="${_tr_p#*|}"; _tr_id="${_tr_id#*|}"; _tr_id="${_tr_id%%|*}"
      if [[ "$_tr_id" == "$target_id" ]]; then
        found_line="$_tr_raw"
        found_state="${_tr_p%%|*}"
        break
      fi
    done < <(_each_item)

    if [[ -z "$found_line" ]]; then
      printf 'deputy: no item with id %s\n' "$target_id" >&2; return 1
    fi
    if [[ "$found_state" != "waiting" && "$found_state" != "paused" ]]; then
      printf 'deputy: item %s is %s, not runnable\n' "$target_id" "$found_state" >&2; return 1
    fi

    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      return 0
    fi
    cmd_claim "$found_line" --pid "$$" >/dev/null 2>&1 || return 1
    # Read item line from line 1 of claim file (claim file now has 2 lines).
    running_line="$(sed -n '1p' "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$found_line")"
    log="$(mktemp)"
    set +e
    _spawn_orchestrator "$running_line" "$decision" >"$log" 2>&1
    rc=$?
    set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    cat "$log"
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; rm -f "$log"
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      # Always-on: do NOT reschedule the shared cron line for quota.
      # The fixed */N heartbeat will retry on the next tick; quota is a per-task skip.
      printf 'deputy: Claude session limit reached — will retry on next heartbeat tick.\n'
      return 0
    fi
    rm -f "$log"
    return 0
  fi

  # ── Normal priority-driven run loop ──────────────────────────────────────────
  while :; do
    item="$(cmd_pick)"; [[ -n "$item" ]] || break
    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      # Provider unavailable: leave item waiting; the next heartbeat tick will retry.
      return 0
    fi
    cmd_claim "$item" --pid "$$" >/dev/null 2>&1 || break
    # Read item line from line 1 of claim file (claim file now has 2 lines).
    running_line="$(sed -n '1p' "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$item")"

    # ── Retry budget check (before spawning) ─────────────────────────────────
    # Extract item id for waypoint lookup; if budget exhausted, mark failed instead.
    local _rb_id _rb_parsed _rb_id_rest
    _rb_parsed="$(_parse_item "$running_line")"
    _rb_id_rest="${_rb_parsed#*|}"; _rb_id_rest="${_rb_id_rest#*|}"; _rb_id="${_rb_id_rest%%|*}"
    if [[ -n "$_rb_id" ]] && _wp_retry_budget_exhausted "$_rb_id"; then
      local _rb_desc; _rb_desc="${_rb_id_rest#*|}"
      local _rb_slug; _rb_slug="$(_wp_slug "$_rb_id" "$_rb_desc")"
      local _fail_reason="cron resume budget exhausted (3 attempts, no step progress)"
      printf '%s\n' "$_fail_reason" > "$STATE_DIR/$_rb_slug.fail.md"
      _with_lock _do_set_item_failed "$running_line" || true
      rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
      processed=$((processed + 1))
      [[ "$once" -eq 1 ]] && break
      [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
      continue
    fi

    log="$(mktemp)"
    set +e
    _spawn_orchestrator "$running_line" "$decision" >"$log" 2>&1
    rc=$?
    set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    cat "$log"   # surface the orchestrator's output (headless log / interactive)
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      # Pass only the relevant reset/limit line(s) to the rescheduler (bounded;
      # avoids ARG_MAX on a large log). _parse_reset_hour scans for "<N>am/pm".
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; rm -f "$log"
      # The orchestrator didn't finish this item — revert it for the next tick.
      # Always-on: do NOT reschedule the shared cron line for quota.
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      # Track that a cron-triggered resume attempt happened with no step progress.
      if [[ -n "$_rb_id" ]]; then
        _wp_increment_resume_attempts "$_rb_id"
        if _wp_retry_budget_exhausted "$_rb_id"; then
          local _qrb_desc; _qrb_desc="${_rb_id_rest#*|}"
          local _qrb_slug; _qrb_slug="$(_wp_slug "$_rb_id" "$_qrb_desc")"
          printf '%s\n' "cron resume budget exhausted (3 attempts, no step progress)" \
            > "$STATE_DIR/$_qrb_slug.fail.md"
          local _qrb_cur_line
          _qrb_cur_line="$(grep -F "[#$_rb_id]" "$BACKLOG" 2>/dev/null | head -1 || true)"
          if [[ -n "$_qrb_cur_line" ]]; then
            _with_lock _revert_to_waiting "$_qrb_cur_line" >/dev/null 2>&1 || true
            _qrb_cur_line="$(grep -F "[#$_rb_id]" "$BACKLOG" 2>/dev/null | head -1 || true)"
            [[ -n "$_qrb_cur_line" ]] && { _with_lock _do_set_item_failed "$_qrb_cur_line" || true; }
          fi
        fi
      fi
      printf 'deputy: Claude session limit reached — will retry on next heartbeat tick.\n'
      return 0
    fi
    # Successful orchestrator exit: track attempt progress.
    # If a new step was committed, the budget resets; otherwise increments attempt counter.
    if [[ -n "$_rb_id" ]]; then
      _wp_track_resume_attempt "$_rb_id"
      # Post-track: if budget is now exhausted (just hit threshold), mark failed.
      if _wp_retry_budget_exhausted "$_rb_id"; then
        local _rb_desc2; _rb_desc2="${_rb_id_rest#*|}"
        local _rb_slug2; _rb_slug2="$(_wp_slug "$_rb_id" "$_rb_desc2")"
        printf '%s\n' "cron resume budget exhausted (3 attempts, no step progress)" \
          > "$STATE_DIR/$_rb_slug2.fail.md"
        # Look up the current BACKLOG line for this item (running_line may still be in BACKLOG
        # if the orchestrator didn't mark the item terminal; search by id tag [#N]).
        local _rb_cur_line
        _rb_cur_line="$(grep -F "[#$_rb_id]" "$BACKLOG" 2>/dev/null | head -1 || true)"
        [[ -n "$_rb_cur_line" ]] && { _with_lock _do_set_item_failed "$_rb_cur_line" || true; }
      fi
    fi
    rm -f "$log"
    processed=$((processed + 1))
    [[ "$once" -eq 1 ]] && break
    [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
  done
  return 0
}

# Remove items of a given state from BACKLOG.md. Default state is "waiting"
# (backward-compatible: bare `deputy clean` removes untouched/waiting items only).
# --dry-run previews only. --state <state> selects a different state to clean.
# Only terminal/inert states are cleanable: waiting, done, failed, cancelled, duplicate.
# Active/checkpointed/awaiting states (running, triaging, surfaced, paused) are refused.
cmd_clean() {
  local dry=0 filter_state="waiting"

  # Arg parsing: tolerant of order; support --state X and --state=X.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --state=*)   filter_state="${1#--state=}"; shift ;;
      --state)
        [[ $# -ge 2 ]] || { printf 'deputy: --state requires an argument\n' >&2; return 2; }
        filter_state="$2"; shift 2 ;;
      *) printf 'deputy: clean: unexpected argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # Safety: refuse to clean active/checkpointed/awaiting states.
  case "$filter_state" in
    waiting|done|failed|cancelled|duplicate|deferred)
      ;;  # cleanable terminal/inert states — ok
    running|triaging|surfaced|paused)
      printf 'deputy: refusing to clean %s items (active/checkpointed/awaiting) — recover or resolve them first\n' \
        "$filter_state" >&2
      return 1 ;;
    *)
      printf 'deputy: clean: unknown state: %s (cleanable: waiting, done, failed, cancelled, duplicate, deferred)\n' \
        "$filter_state" >&2
      return 2 ;;
  esac

  local raw parsed state
  local -a doomed=()
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    [[ "$state" == "$filter_state" ]] && doomed+=("$raw")
  done < <(_each_item)

  if [[ "${#doomed[@]}" -eq 0 ]]; then printf 'deputy: nothing to clean\n'; return 0; fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'deputy: would remove %d %s item(s):\n' "${#doomed[@]}" "$filter_state"
    printf '  %s\n' "${doomed[@]}"
    return 0
  fi
  _do_clean() {
    local tmp line d r prev_blank=0
    tmp="$(mktemp "$(dirname "$BACKLOG")/.backlog.tmp.XXXXXX")"
    chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
      d=0
      for r in "${doomed[@]}"; do [[ "$line" == "$r" ]] && { d=1; break; }; done
      [[ "$d" -eq 1 ]] && continue
      if [[ -z "${line//[[:space:]]/}" ]]; then
        [[ "$prev_blank" -eq 1 ]] && continue
        prev_blank=1
      else
        prev_blank=0
      fi
      printf '%s\n' "$line"
    done < "$BACKLOG" > "$tmp"
    mv "$tmp" "$BACKLOG"
    _regroup_backlog
  }
  _with_lock _do_clean
  printf 'deputy: cleaned %d %s item(s)\n' "${#doomed[@]}" "$filter_state"
}

# Find all duplicate candidate pairs from a list of descriptions (one per stdin line).
# Prints "N\tDesc1\tDesc2" for each pair sharing ≥3 significant words (>3 chars).
# All N² comparisons run inside a single awk process — no per-pair subshells.
_reflect_find_duplicates() {
  awk -v threshold=3 '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      delete w
      n1 = split(tolower(lines[i]), a, " ")
      for (k = 1; k <= n1; k++) {
        gsub(/[^a-z]/, "", a[k])
        if (length(a[k]) > 3) w[a[k]] = 1
      }
      for (j = i + 1; j <= NR; j++) {
        c = 0; delete seen
        n2 = split(tolower(lines[j]), b, " ")
        for (k = 1; k <= n2; k++) {
          gsub(/[^a-z]/, "", b[k])
          if (length(b[k]) > 3 && (b[k] in w) && !(b[k] in seen)) {
            seen[b[k]] = 1; c++
          }
        }
        if (c >= threshold) printf "%d\t%s\t%s\n", c, lines[i], lines[j]
      }
    }
  }'
}

# Show a structured reflect report: learnings (done items), items needing re-triage
# (untagged), full reprioritization list, surfaced items, and potential duplicates.
# --apply: also writes .deputy/learnings.md (fresh snapshot of done items).
cmd_reflect() {
  _with_lock _allocate_ids
  local apply=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --apply) apply=1; shift ;;
    *) printf 'deputy: reflect: unexpected arg: %s\n' "$1" >&2; return 2 ;;
  esac; done

  local raw parsed state prio desc _rrest _rid
  local -a done_items=() waiting_items=() surfaced_items=()

  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    local rest="${parsed#*|}"
    prio="${rest%%|*}"
    _rrest="${rest#*|}"; _rid="${_rrest%%|*}"; desc="${_rrest#*|}"
    case "$state" in
      done)     done_items+=("${prio}|${desc}") ;;
      waiting|paused) waiting_items+=("${prio}|${desc}") ;;
      surfaced) surfaced_items+=("${prio}|${desc}") ;;
    esac
  done < <(_each_item)

  printf '%s\n\n' "=== Deputy Reflect ==="

  # 1. Learnings — what has been shipped
  printf '%s\n' "-- Learnings (${#done_items[@]} done) --"
  if [[ "${#done_items[@]}" -eq 0 ]]; then
    printf '  (no done items)\n'
  else
    for item in "${done_items[@]}"; do
      local p="${item%%|*}" d="${item#*|}"
      printf '  # %s%s\n' "${p:+[$p] }" "$d"
    done
  fi
  printf '\n'

  # 2. Needs re-triage — untagged waiting items (no [Px] priority)
  printf '%s\n' "-- Needs re-triage (untagged waiting items) --"
  local untagged=0
  for item in "${waiting_items[@]}"; do
    local p="${item%%|*}" d="${item#*|}"
    if [[ -z "$p" ]]; then
      printf '  ? %s\n' "$d"
      untagged=$((untagged + 1))
    fi
  done
  [[ "$untagged" -eq 0 ]] && printf '  (none: all waiting items have a priority)\n'
  printf '\n'

  # 3. Reprioritization — full waiting list ordered as-is
  printf '%s\n' "-- Waiting items (reprioritization review) --"
  if [[ "${#waiting_items[@]}" -eq 0 ]]; then
    printf '  (no waiting items)\n'
  else
    for item in "${waiting_items[@]}"; do
      local p="${item%%|*}" d="${item#*|}"
      printf '  [%s] %s\n' "${p:-??}" "$d"
    done
  fi
  printf '\n'

  # 4. Surfaced — pending human response
  printf '%s\n' "-- Surfaced items (awaiting human response) --"
  if [[ "${#surfaced_items[@]}" -eq 0 ]]; then
    printf '  (none)\n'
  else
    for item in "${surfaced_items[@]}"; do
      printf '  ? %s\n' "${item#*|}"
    done
  fi
  printf '\n'

  # 5. Potential duplicates — pairs sharing ≥3 significant words (operator reviews).
  # All comparisons happen inside a single awk process (no per-pair forks).
  printf '%s\n' "-- Potential duplicates (review manually; use: deputy set \"<line>\" duplicate) --"
  local -a all_items=("${done_items[@]}" "${waiting_items[@]}")
  local found_dups=0
  if [[ "${#all_items[@]}" -ge 2 ]]; then
    local dup_line overlap di dj
    while IFS=$'\t' read -r overlap di dj; do
      printf '  CANDIDATE: "%s"\n       vs.: "%s"\n       (shared words: %s)\n' \
        "$di" "$dj" "$overlap"
      found_dups=$((found_dups + 1))
    done < <(printf '%s\n' "${all_items[@]#*|}" | _reflect_find_duplicates)
  fi
  [[ "$found_dups" -eq 0 ]] && printf '  (no candidates detected)\n'
  printf '\n'

  # 6. Write learnings snapshot if --apply
  if [[ "$apply" -eq 1 ]]; then
    local lf="$STATE_DIR/learnings.md"
    local -a snap_items=("${done_items[@]}")
    _do_write_learnings() {
      local tmp; tmp="$(mktemp "$STATE_DIR/.learnings.XXXXXX")"
      {
        printf '# Deputy Learnings Snapshot\n'
        printf '# Generated: %s\n\n' "$(date -Iseconds 2>/dev/null || date)"
        if [[ "${#snap_items[@]}" -eq 0 ]]; then
          printf '%s\n' "_No done items yet._"
        else
          for item in "${snap_items[@]}"; do
            local p="${item%%|*}" d="${item#*|}"
            printf '%s\n' "- ${p:+[$p] }${d}"
          done
        fi
      } > "$tmp" && mv "$tmp" "$lf" || { rm -f "$tmp"; return 1; }
    }
    _with_lock _do_write_learnings
    printf 'deputy: learnings snapshot written to %s\n' "$lf"
  fi
}

# ── Checkpoint spine (absorbed waypoint), stored under .deputy/waypoints/ ──────
_wp_task_dir() { printf '%s/waypoints/%s' "$STATE_DIR" "$1"; }
_wp_json()     { printf '%s/waypoints/%s/waypoint.json' "$STATE_DIR" "$1"; }
_wp_now()      { date -Iseconds; }
_wp_require_jq(){ command -v jq >/dev/null 2>&1 || { printf 'deputy: jq is required for the checkpoint spine\n' >&2; return 1; }; }

# Apply a jq filter to a task's waypoint.json, atomically; regenerate STATUS.md.
# Caller holds .deputy/lock.
_wp_jq() {
  local id="$1" filter="$2"; shift 2
  local f tmp; f="$(_wp_json "$id")"
  tmp="$(mktemp "$(dirname "$f")/.wp.XXXXXX")"
  # Guard the write: if jq fails, do NOT mv (an empty/partial tmp would truncate
  # the ledger). Only replace on success.
  if jq "$@" "$filter" "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
  _wp_render_status "$id"
}

# Regenerate the human-readable STATUS.md from waypoint.json.
# Writes to a temp file first then mv for atomicity.
_wp_render_status() {
  local id="$1" f td tmp; f="$(_wp_json "$id")"; td="$(_wp_task_dir "$id")"
  tmp="$(mktemp "$td/.status.XXXXXX")"
  { jq -r '"# Task: \(.task_id)   (\(.status))\n\n**Goal:** \(.goal)\n\n## Steps"' "$f"
    jq -r '.steps[] | (if .status=="succeeded" then "[x] " elif .status=="in_progress" then "[>] " else "[ ] " end) + .id + "  " + .purpose' "$f"
  } > "$tmp" && mv "$tmp" "$td/STATUS.md" || { rm -f "$tmp"; return 1; }
}

_wp_validate_id() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || {
    printf 'deputy: invalid waypoint id (alphanumeric, dot, dash, underscore only): %s\n' "$1" >&2
    return 1
  }
}

cmd_wp_start() {
  local id="${1:?start needs <id>}" goal="${2:-}"
  _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1
  _do_start() {
    [[ -f "$(_wp_json "$id")" ]] && return 0        # idempotent: never clobber (checked inside lock)
    local td; td="$(_wp_task_dir "$id")"; mkdir -p "$td"
    local now; now="$(_wp_now)"
    local _jtmp; _jtmp="$(mktemp "$td/.wp.XXXXXX")"
    jq -n --arg id "$id" --arg g "$goal" --arg now "$now" \
      '{task_id:$id, goal:$g, status:"in_progress", created_at:$now, updated_at:$now, note:"", current_step:null, steps:[]}' \
      > "$_jtmp" && mv "$_jtmp" "$(_wp_json "$id")" \
      || { rm -f "$_jtmp"; printf 'deputy: failed to write waypoint.json for %s\n' "$id" >&2; return 1; }
    _wp_render_status "$id"
  }
  _with_lock _do_start
}

cmd_wp_done() {
  local id="${1:?done needs <id>}"; _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1
  _do_done() {
    # Guard (inside lock): all steps must be succeeded before marking the task done.
    if jq -e 'any(.steps[]; .status!="succeeded")' "$(_wp_json "$id")" >/dev/null; then
      printf 'deputy: done: not all steps succeeded for %s\n' "$id" >&2; return 1
    fi
    _wp_jq "$id" '.status="completed" | .current_step=null | .updated_at=$now' --arg now "$(_wp_now)"
  }
  _with_lock _do_done
}

cmd_wp_plan() {
  local id="" sid="" purpose=""
  id="${1:?plan needs <id>}"; shift
  _wp_validate_id "$id" || return 1
  while [[ $# -gt 0 ]]; do case "$1" in
    --step)    [[ $# -ge 2 ]] || { printf 'deputy: plan: --step requires a value\n' >&2; return 2; }; sid="$2"; shift 2 ;;
    --purpose) [[ $# -ge 2 ]] || { printf 'deputy: plan: --purpose requires a value\n' >&2; return 2; }; purpose="$2"; shift 2 ;;
    *) printf 'deputy: plan: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  [[ -n "$sid" && -n "$purpose" ]] || { printf 'deputy: plan needs --step and --purpose\n' >&2; return 2; }
  _wp_require_jq || return 1
  _do_plan() {
    # Guard (inside lock): reject duplicate step id.
    if jq -e --arg sid "$sid" 'any(.steps[]; .id==$sid)' "$(_wp_json "$id")" >/dev/null; then
      printf 'deputy: plan: step id %s already exists in %s\n' "$sid" "$id" >&2; return 1
    fi
    _wp_jq "$id" \
      '.steps += [{id:$sid, purpose:$p, expected_result:"", status:"pending", completed_at:null, actual_result:null}] | .updated_at=$now' \
      --arg sid "$sid" --arg p "$purpose" --arg now "$(_wp_now)"
  }
  _with_lock _do_plan
}

cmd_wp_steps() {
  local id="${1:?steps needs <id>}"; _wp_validate_id "$id" || return 1; _wp_require_jq || return 1
  jq -r '.steps[] | "\(.id)|\(.status)|\(.purpose)"' "$(_wp_json "$id")"
}

cmd_wp_setstep() {
  local id="" sid="" expected=""
  id="${1:?set-step needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --step) [[ $# -ge 2 ]] || { printf 'deputy: set-step --step needs a value\n' >&2; return 2; }; sid="$2"; shift 2 ;;
    --expected) [[ $# -ge 2 ]] || { printf 'deputy: set-step --expected needs a value\n' >&2; return 2; }; expected="$2"; shift 2 ;;
    *) printf 'deputy: set-step: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  [[ -n "$sid" ]] || { printf 'deputy: set-step needs --step\n' >&2; return 2; }
  _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1
  _do_setstep() {
    # Guard: refuse to advance current_step to a non-existent step id.
    if ! jq -e --arg sid "$sid" 'any(.steps[]; .id == $sid)' "$(_wp_json "$id")" >/dev/null; then
      printf 'deputy: set-step: step id %s not found in %s\n' "$sid" "$id" >&2; return 1
    fi
    # Guard: refuse to re-activate a step that already succeeded.
    if jq -e --arg sid "$sid" 'any(.steps[]; .id==$sid and .status=="succeeded")' "$(_wp_json "$id")" >/dev/null; then
      printf 'deputy: set-step: step %s already succeeded in %s\n' "$sid" "$id" >&2; return 1
    fi
    _wp_jq "$id" \
      '.steps |= map(if .status=="in_progress" then .status="pending" else . end)
       | (.steps[] | select(.id==$sid) | .status) = "in_progress"
       | (.steps[] | select(.id==$sid) | .expected_result) = $e
       | .current_step = $sid | .updated_at=$now' \
      --arg sid "$sid" --arg e "$expected" --arg now "$(_wp_now)"
  }
  _with_lock _do_setstep
}

# Print "<id>|<purpose>" of the first step not yet succeeded (empty if none).
cmd_wp_resume() {
  local id="${1:?resume needs <id>}"; _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1
  jq -r 'first(.steps[] | select(.status!="succeeded")) | "\(.id)|\(.purpose)"' \
    "$(_wp_json "$id")"
}

cmd_wp_commit() {
  local id="" summary="" allow_empty=0; local -a arts=()
  id="${1:?commit needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --summary) [[ $# -ge 2 ]] || { printf 'deputy: commit --summary needs a value\n' >&2; return 2; }; summary="$2"; shift 2 ;;
    --artifact) [[ $# -ge 2 ]] || { printf 'deputy: commit --artifact needs a value\n' >&2; return 2; }; arts+=("$2"); shift 2 ;;
    --allow-empty) allow_empty=1; shift ;;
    *) printf 'deputy: commit: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1
  local wt; wt="$(_wt_path)"
  [[ -d "$wt/.git" || -e "$wt/.git" ]] || { printf 'deputy: no worktree at %s\n' "$wt" >&2; return 1; }
  # Guard: require an in_progress step; without one the ledger update is a no-op.
  if ! jq -e 'any(.steps[]; .status=="in_progress")' "$(_wp_json "$id")" >/dev/null 2>&1; then
    printf 'deputy: commit: no in_progress step in %s\n' "$id" >&2; return 1
  fi
  # NOTE: git commit happens before the ledger write (and outside the lock) on
  # purpose. If we die between them, the step stays in_progress and resume re-runs
  # it — producing one redundant (harmless) commit. Reversing this could mark a
  # step succeeded with no commit. Do not reorder.
  # Stage ALL changes. A step MUST produce a committed change to succeed: if nothing
  # is staged, fail (step stays in_progress) unless --allow-empty was given.
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then
    if [[ "$allow_empty" -ne 1 ]]; then
      printf 'deputy: commit: no changes staged in %s — a step must produce a committed change (use --allow-empty to override)\n' "$wt" >&2
      return 1
    fi
    git -C "$wt" commit -q --allow-empty -m "${summary:-deputy step (no changes)}"
  else
    git -C "$wt" commit -q -m "${summary:-deputy step}"
  fi
  local sha; sha="$(git -C "$wt" rev-parse HEAD)"
  # artifacts: declared paths (or "." if none), each tagged with the SHA.
  local arts_json
  if [[ "${#arts[@]}" -eq 0 ]]; then arts=("."); fi
  arts_json="$(printf '%s\n' "${arts[@]}" | jq -R --arg sha "$sha" '{path:., step_commit:$sha}' | jq -s '.')"
  _do_commit() {
    _wp_jq "$id" \
      '(.steps[] | select(.status=="in_progress")) |=
         (.status="succeeded" | .completed_at=$now
          | .actual_result={summary:$sum, artifacts:$arts})
       | .current_step=null | .updated_at=$now' \
      --arg sum "$summary" --arg now "$(_wp_now)" --argjson arts "$arts_json"
  }
  _with_lock _do_commit
}

# Hidden helper for tests: print the raw waypoint.json.
cmd_wp_show() { cat "$(_wp_json "${1:?}")"; }

# ── Retry budget helpers ─────────────────────────────────────────────────────
# Budget: if an item has been cron-resumed 3 times with no new committed step,
# stop reviving it (mark it failed). Stored in waypoint.json as `resume_attempts`
# (an integer; absent = 0) and `resume_attempts_committed_steps` (count of
# succeeded steps at the last attempt; if step count grew → reset budget).
#
# The budget only applies when a waypoint exists for the item.
# Items without a waypoint (no waypoints/ dir) are not budgeted.

# Maximum no-progress resumes before marking the item failed.
_WP_RETRY_BUDGET=3

# Convert item id + description to a safe filesystem slug for .fail.md filenames.
_wp_slug() {
  local id="$1" desc="$2"
  local slug="${id}-${desc}"
  # Replace non-alphanumeric characters with dashes; collapse consecutive dashes; trim.
  slug="$(printf '%s' "$slug" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s' "${slug:0:64}"
}

# Return 0 (true) if the retry budget is exhausted for item <id>.
# Budget is exhausted if resume_attempts >= _WP_RETRY_BUDGET AND no new step committed.
_wp_retry_budget_exhausted() {
  local id="$1"
  local f; f="$(_wp_json "$id")"
  [[ -f "$f" ]] || return 1   # no waypoint → not budgeted
  command -v jq >/dev/null 2>&1 || return 1
  local attempts prev_steps current_steps
  attempts="$(jq -r '.resume_attempts // 0' "$f" 2>/dev/null || printf '0')"
  prev_steps="$(jq -r '.resume_attempts_committed_steps // 0' "$f" 2>/dev/null || printf '0')"
  current_steps="$(jq -r '[.steps[] | select(.status=="succeeded")] | length' "$f" 2>/dev/null || printf '0')"
  # If steps grew since last attempt, reset: not exhausted.
  if [[ "$current_steps" -gt "$prev_steps" ]]; then return 1; fi
  # Otherwise check attempt counter.
  [[ "$attempts" -ge "$_WP_RETRY_BUDGET" ]]
}

# Increment resume_attempts for item <id> (no-op if no waypoint). Lock-free; caller
# may or may not hold the lock — this uses its own atomic write.
_wp_increment_resume_attempts() {
  local id="$1"
  local f; f="$(_wp_json "$id")"
  [[ -f "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  _do_inc() {
    local current_steps
    current_steps="$(jq -r '[.steps[] | select(.status=="succeeded")] | length' "$f" 2>/dev/null || printf '0')"
    _wp_jq "$id" \
      '.resume_attempts = ((.resume_attempts // 0) + 1)
       | .resume_attempts_committed_steps = ($cs | tonumber)
       | .updated_at = $now' \
      --arg cs "$current_steps" --arg now "$(_wp_now)"
  }
  _with_lock _do_inc 2>/dev/null || true
}

# After a successful (non-quota) orchestrator exit: if step count grew, reset budget;
# otherwise increment attempt counter. No-op if no waypoint exists.
_wp_track_resume_attempt() {
  local id="$1"
  local f; f="$(_wp_json "$id")"
  [[ -f "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  _do_track() {
    local prev_steps current_steps
    prev_steps="$(jq -r '.resume_attempts_committed_steps // 0' "$f" 2>/dev/null || printf '0')"
    current_steps="$(jq -r '[.steps[] | select(.status=="succeeded")] | length' "$f" 2>/dev/null || printf '0')"
    if [[ "$current_steps" -gt "$prev_steps" ]]; then
      # Progress was made: reset the retry budget.
      _wp_jq "$id" \
        '.resume_attempts = 0
         | .resume_attempts_committed_steps = ($cs | tonumber)
         | .updated_at = $now' \
        --arg cs "$current_steps" --arg now "$(_wp_now)"
    else
      # No progress: increment attempt counter.
      _wp_jq "$id" \
        '.resume_attempts = ((.resume_attempts // 0) + 1)
         | .resume_attempts_committed_steps = ($cs | tonumber)
         | .updated_at = $now' \
        --arg cs "$current_steps" --arg now "$(_wp_now)"
    fi
  }
  _with_lock _do_track 2>/dev/null || true
}

# Set a running item's state to failed in BACKLOG (used by retry budget exhaustion).
# Caller holds no lock (this acquires its own via _with_lock).
_do_set_item_failed() {
  local raw="$1" parsed prio desc to _fsid_rest _fsid
  parsed="$(_parse_item "$raw")"
  prio="${parsed#*|}"; prio="${prio%%|*}"
  _fsid_rest="${parsed#*|}"; _fsid_rest="${_fsid_rest#*|}"; _fsid="${_fsid_rest%%|*}"
  desc="${_fsid_rest#*|}"
  to="$(_serialize_item failed "$prio" "$_fsid" "$desc")"
  _flip_line "$raw" "$to"
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    _parse) _parse_item "${2:-}"; printf '\n'; return 0 ;;
    list) cmd_list; return 0 ;;
    _serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}" "${5:-}" && printf '\n' || return 1 ;;
    add) shift; cmd_add "$@" ;;
    status) cmd_status; return 0 ;;
    pick) cmd_pick; return 0 ;;
    set) shift; cmd_set "$@"; return $? ;;
    claim) shift; cmd_claim "$@"; return $? ;;
    recover) cmd_recover; return 0 ;;
    review) cmd_review; return 0 ;;
    clean) shift; cmd_clean "$@"; return $? ;;
    reflect) shift; cmd_reflect "$@"; return $? ;;
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
    route) shift; _route "${1:-}" "${2:-}"; return $? ;;
    probe) shift; _probe "${1:-}"; return 0 ;;
    cron) shift; cmd_cron "$@"; return $? ;;
    _resethour) shift; _parse_reset_hour "${1:-}"; return 0 ;;
    _resetsecs) shift; _parse_reset_secs "${1:-}"; return 0 ;;
    config) shift; _config_get "${1:-}"; return 0 ;;
    protected) shift
      if [[ "${1:-}" == "--stdin" ]]; then _protected_violation "$(cat)"; else _protected_violation "${1:-}"; fi
      return $? ;;
    wt-create) shift; _wt_create "${1:?slug}"; return $? ;;
    wt-remove) shift; _wt_remove; return $? ;;
    run) shift; cmd_run "$@"; return 0 ;;
    start) shift; cmd_wp_start "$@"; return $? ;;
    done) shift; cmd_wp_done "$@"; return $? ;;
    plan) shift; cmd_wp_plan "$@"; return $? ;;
    steps) shift; cmd_wp_steps "$@"; return $? ;;
    set-step) shift; cmd_wp_setstep "$@"; return $? ;;
    resume) shift; cmd_wp_resume "$@"; return $? ;;
    commit) shift; cmd_wp_commit "$@"; return $? ;;
    _wp_show) shift; cmd_wp_show "$@"; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
