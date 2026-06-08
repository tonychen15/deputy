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

# Parse one raw line -> "state|priority|description". Lenient: accepts an optional
# space after the status prefix (so both `#[P0] x` and `# [P0] x` parse the same).
_parse_item() {
  local line="$1" state="waiting" prio="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?#!%=^])[[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;;  '@') state=running ;;    '?') state=surfaced ;;
      '#') state=done ;;      '!') state=failed ;;
      '%') state=cancelled ;; '=') state=duplicate ;; '^') state=paused ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  if [[ "$line" =~ ^\[(P[0-2])\][[:space:]]*(.*)$ ]]; then
    prio="${BASH_REMATCH[1]}"
    desc="${BASH_REMATCH[2]}"
  else
    desc="$line"
  fi
  printf '%s|%s|%s' "$state" "$prio" "$desc"
}

# Build a canonical line from (state, priority, description). The status symbol
# directly abuts what follows (no space): `#[P0] x`, `#Refactor`, `[P2] x`, `Plain`.
_serialize_item() {
  local state="$1" prio="$2" desc="$3" prefix="" body=""
  case "$state" in
    waiting)   prefix="" ;;  triaging)  prefix="~" ;; running)   prefix="@" ;;
    surfaced)  prefix="?" ;; done)      prefix="#" ;; failed)    prefix="!" ;;
    cancelled) prefix="%" ;; duplicate) prefix="=" ;; paused)    prefix="^" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  if [[ -n "$prio" ]]; then
    if [[ -n "$desc" ]]; then body="[$prio] $desc"; else body="[$prio]"; fi
  else
    body="$desc"
  fi
  printf '%s%s' "$prefix" "$body"
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

# Append a raw line preceded by a blank line so items stay blank-separated.
# Caller holds the lock.
_append_item() { printf '\n%s\n' "$1" >> "$BACKLOG"; }

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
  if [[ "$text" =~ ^[~@?#!%=^] ]] || [[ "$text" =~ ^\[P[0-2]\] ]]; then
    printf 'deputy: description may not begin with a status prefix (~@?#!%%=^) or a [Px] tag: %s\n' "$text" >&2
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
  # Trigger execution immediately if nothing is running and work is available.
  # Set DEPUTY_NO_AUTORUN=1 to suppress (used in tests that exercise add in isolation).
  if [[ "${DEPUTY_NO_AUTORUN:-0}" != "1" ]] && ! _live_claim_exists && [[ -n "$(cmd_pick)" ]]; then
    cmd_run --once
  fi
}

cmd_status() {
  local raw state w=0 t=0 r=0 s=0 d=0 f=0 c=0 u=0 p=0 parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting) w=$((w+1)) ;; triaging) t=$((t+1)) ;; running)    r=$((r+1)) ;;
      surfaced) s=$((s+1)) ;; done) d=$((d+1)) ;;    failed)     f=$((f+1)) ;;
      cancelled) c=$((c+1)) ;; duplicate) u=$((u+1)) ;; paused)  p=$((p+1)) ;;
    esac
  done < <(_each_item)
  printf 'waiting:  %d\ntriaging: %d\nrunning:  %d\nsurfaced: %d\ndone:     %d\nfailed:   %d\ncancelled: %d\nduplicate: %d\npaused:   %d\n' \
    "$w" "$t" "$r" "$s" "$d" "$f" "$c" "$u" "$p"
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
  case "$1" in waiting|triaging|running|surfaced|done|failed|cancelled|duplicate|paused) return 0 ;; *) return 1 ;; esac
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
    [[ "$state" == "waiting" || "$state" == "paused" ]] || { printf 'deputy: item is not waiting/paused (%s)\n' "$state" >&2; return 4; }
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

cmd_review() {
  local any=0 raw parsed state desc f
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    [[ "$state" == "surfaced" ]] || continue
    desc="${parsed#*|*|}"
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
  list                            print parsed items (state|priority|description)
  status                          counts by state
  run [--once]                    work the backlog: claim the top item, run the orchestrator
  pick                            print the highest-priority waiting item (raw line)
  set "<exact line>" <state>      transition an item's state by exact-line match
  claim "<exact line>" [--pid N]  mark an item running and write a claim (serial)
  recover                         revert stale/orphaned claims to waiting
  probe <cli>                     check a provider's availability
  route <kind> <avail-csv>        choose a provider (orchestrate|code-complex|code-simple|review)
  cron --ensure|--remove|--reschedule "<text>"   manage the safety-net schedule
  detect <cli> <rc> <log>         (internal) classify a CLI outcome
  review                          show surfaced items, their questions, and the digest
  clean [--dry-run]               remove untouched (waiting) items; keeps everything deputy has touched
  help                            show this message

states: waiting triaging running surfaced done failed cancelled duplicate paused
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

# Extract a 24h hour from "resets 11pm" / "resets 3am". Echoes nothing if no match.
_parse_reset_hour() {
  local s="${1,,}" h ampm
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
    --ensure)     _set_cron "*/15 * * * *" ;;
    --remove)     _set_cron "" ;;
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
  claude -p "$prompt" --model claude-sonnet-4-6 --allowedTools "Bash,Edit,Write,Read,Glob,Grep"
}

# Re-arm this repo's heartbeat if the repo is cron-enabled but the */15 line is
# missing (e.g. a prior quota reschedule replaced it). No-op if already correct or
# if the repo was never cron-enabled — so a manual run never surprise-installs cron.
_cron_selfarm() {
  local root marker existing; root="$(resolve_root)"; marker="# deputy[$root]"
  existing="$(_crontab -l 2>/dev/null || true)"
  printf '%s\n' "$existing" | grep -qF "$marker" || return 0          # not enabled → skip
  # Check the line that owns this repo's marker starts with */15 (schedule-only check,
  # avoids quoting discrepancies in the cd path).
  printf '%s\n' "$existing" | grep -F "$marker" | grep -q '^[*]/15 ' && return 0  # already armed
  cmd_cron --ensure >/dev/null 2>&1 || true
}

# One tick: claim the top item and hand it to the orchestrator. --once = no loop.
cmd_run() {
  local once=0; [[ "${1:-}" == "--once" ]] && once=1
  cmd_recover >/dev/null 2>&1 || true
  _cron_selfarm
  if _live_claim_exists; then return 0; fi
  # Optional per-cycle cap; 0/empty/non-numeric = unlimited (run until the queue is
  # empty or Claude's session limit is hit).
  local cap; cap="$(_config_get max_items)"; cap="${cap:-0}"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
  local processed=0 item avail decision running_line log rc outcome reset
  while :; do
    item="$(cmd_pick)"; [[ -n "$item" ]] || break
    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      cmd_cron --reschedule "orchestrator unavailable" >/dev/null 2>&1 || true
      break
    fi
    cmd_claim "$item" --pid "$$" >/dev/null 2>&1 || break
    running_line="$(cat "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$item")"
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
      # The orchestrator didn't finish this item — revert it for the next cycle,
      # reschedule cron for the reset time, and stop (research.sh behavior).
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      cmd_cron --reschedule "$reset" >/dev/null 2>&1 || true
      printf 'deputy: Claude session limit reached — rescheduled for reset; stopping this cycle.\n'
      return 0
    fi
    rm -f "$log"
    processed=$((processed + 1))
    [[ "$once" -eq 1 ]] && break
    [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
  done
  return 0
}

# Remove UNTOUCHED (waiting) items from BACKLOG.md — the ones deputy has never
# acted on. Keeps everything deputy has touched (triaging/running/surfaced/done/
# failed/cancelled/duplicate). --dry-run previews only. The real pass is
# lock-serialized + atomic and squeezes any resulting consecutive blanks.
cmd_clean() {
  local dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
  local raw parsed state
  local -a doomed=()
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in waiting) doomed+=("$raw") ;; esac
  done < <(_each_item)
  if [[ "${#doomed[@]}" -eq 0 ]]; then printf 'deputy: nothing to clean\n'; return 0; fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'deputy: would remove %d untouched item(s):\n' "${#doomed[@]}"
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
  }
  _with_lock _do_clean
  printf 'deputy: cleaned %d untouched item(s)\n' "${#doomed[@]}"
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
    review) cmd_review; return 0 ;;
    clean) shift; cmd_clean "$@"; return $? ;;
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
    route) shift; _route "${1:-}" "${2:-}"; return $? ;;
    probe) shift; _probe "${1:-}"; return 0 ;;
    cron) shift; cmd_cron "$@"; return $? ;;
    _resethour) shift; _parse_reset_hour "${1:-}"; return 0 ;;
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

main "$@"
