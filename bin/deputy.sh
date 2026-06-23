#!/usr/bin/env bash
# deputy.sh — the Deputy runner (queue plumbing). Stateless tooling: it reads and
# mutates BACKLOG.md + .deputy/ under a repo root. No LLM logic lives here.

# #50: Decouple the EXECUTED deputy from its live working-tree source. At startup, re-exec
# from an immutable, content-addressed snapshot under the user cache, so editing or merging
# bin/deputy.sh mid-run can't truncate a running invocation (the #44/#50 crash). The dev
# symlink (~/.local/bin/deputy -> repo/bin/deputy.sh) is preserved; the snapshot is reused
# across runs by content hash and rebuilt only when the source changes. This runs BEFORE
# 'set -euo pipefail' so the guard can't trip errexit, and falls back to running in place if
# it can't snapshot. DEPUTY_REEXEC prevents an exec loop; SRC_DIR is preserved so the
# re-exec'd copy still resolves the real install dir; exec preserves TTY (for #51 headed),
# args, stdin and exit code. Only fires when deputy is EXECUTED as the main program
# (BASH_SOURCE==$0) — never when a test sources this file to unit-test internal functions.
if [[ -z "${DEPUTY_REEXEC:-}" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _dep_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  if [[ -r "$_dep_self" ]] && command -v sha256sum >/dev/null 2>&1; then
    _dep_cache="${XDG_CACHE_HOME:-$HOME/.cache}/deputy"
    _dep_sha="$(sha256sum "$_dep_self" 2>/dev/null | cut -c1-16)"
    _dep_snap="$_dep_cache/deputy-${_dep_sha}.sh"
    # Fast path: a snapshot whose CONTENT hashes to the current source already exists
    # (self-verifying — the on-disk name must match the on-disk content).
    if [[ -n "$_dep_sha" && -s "$_dep_snap" ]]; then
      _dep_snap_sha="$(sha256sum "$_dep_snap" 2>/dev/null | cut -c1-16)"
      if [[ "$_dep_snap_sha" == "$_dep_sha" ]]; then
        export DEPUTY_REEXEC=1
        export SRC_DIR="${SRC_DIR:-$(cd "$(dirname "$_dep_self")/.." && pwd)}"
        exec bash "$_dep_snap" "$@"
      fi
    fi
    # Slow path: build it — copy, verify syntax (rejects a mid-write/truncated source),
    # hash the COPY (no TOCTOU), publish under the copy's own hash via atomic rename.
    if mkdir -p "$_dep_cache" 2>/dev/null; then
      _dep_tmp="$_dep_cache/.build.$$.${RANDOM}"
      if cp "$_dep_self" "$_dep_tmp" 2>/dev/null && bash -n "$_dep_tmp" 2>/dev/null; then
        _dep_sha2="$(sha256sum "$_dep_tmp" 2>/dev/null | cut -c1-16)"
        if [[ -n "$_dep_sha2" ]]; then
          _dep_snap2="$_dep_cache/deputy-${_dep_sha2}.sh"
          mv -f "$_dep_tmp" "$_dep_snap2" 2>/dev/null
          if [[ -s "$_dep_snap2" ]]; then
            export DEPUTY_REEXEC=1
            export SRC_DIR="${SRC_DIR:-$(cd "$(dirname "$_dep_self")/.." && pwd)}"
            exec bash "$_dep_snap2" "$@"
          fi
        fi
      fi
      rm -f "$_dep_tmp" 2>/dev/null
    fi
  fi
  export DEPUTY_REEXEC=1   # could not snapshot -> run in place (no re-exec loop)
fi
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
ACTIVE_RUN_DIR="$STATE_DIR/active-run.lock"
mkdir -p "$STATE_DIR"
[[ -f "$LOCK_FILE" ]] || : > "$LOCK_FILE"

# True (0) only for real item lines. Excludes blank lines, markdown section
# headings (TWO-or-more '#' followed by whitespace, e.g. '## Items',
# '### Running (2)') and HTML comments / release delimiters
# ('<!-- release vX — date -->'). Status prefixes are single non-'#' punctuation
# (done '+', deferred ';', etc.; '#'/'>' are still read for back-compat), so item
# lines never collide with the TWO-or-more-'#' heading rule; the H1 title
# '# Deputy Backlog' lives above '## Items' and never reaches here. Single source
# of truth shared by _each_item and _allocate_ids so the two loops can't drift.
_is_item_line() {
  local l="$1"
  l="${l#"${l%%[![:space:]]*}"}"           # left-trim
  [[ -z "$l" ]] && return 1                 # blank
  [[ "$l" =~ ^##+[[:space:]] ]] && return 1 # markdown heading (## / ###), not '# done item'
  case "$l" in '<!--'*) return 1 ;; esac    # HTML comment / release delimiter
  return 0
}

# True (0) only for real release-delimiter lines matching the exact deputy format:
# '<!-- release vX.Y.Z — YYYY-MM-DD -->'. Anchored to the date pattern to avoid
# matching arbitrary HTML comments like '<!-- release notes -->'.
_is_release_delim_line() {
  local l="$1"
  l="${l#"${l%%[![:space:]]*}"}"   # left-trim
  case "$l" in
    '<!-- release v'*' — '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' -->')
      return 0 ;;
  esac
  return 1
}

# Yield raw item lines: everything after the "## Items" heading. Falls back to
# after a legacy "<!-- ... -->" legend, else every non-blank line. Non-item lines
# (blanks, '###' section headers, release delimiters) are skipped for iteration
# (but left intact in the file).
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
    _is_item_line "$line" || continue
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
  if [[ "$line" =~ ^([~@?+!%=^\;#>])[[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;;  '@') state=running ;;    '?') state=surfaced ;;
      '+') state=done ;;      '!') state=failed ;;
      '%') state=cancelled ;; '=') state=duplicate ;; '^') state=paused ;;
      ';') state=deferred ;;
      # Back-compat read of the pre-migration prefixes ('#' done, '>' deferred);
      # _serialize_item always writes the new symbols, so any old line migrates to
      # '+'/';' the next time it is re-serialized (e.g. on _regroup_backlog).
      '#') state=done ;;      '>') state=deferred ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  # Tag zone: consume [Pn] and [#N] in either order (both optional, at most one each).
  local consumed=1
  while [[ "$consumed" -eq 1 ]]; do
    consumed=0
    if [[ -z "$prio" && "$line" =~ ^\[(P[0-4])\][[:space:]]*(.*) ]]; then
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
    surfaced)  prefix="?" ;; done)      prefix="+" ;; failed)    prefix="!" ;;
    cancelled) prefix="%" ;; duplicate) prefix="=" ;; paused)    prefix="^" ;;
    deferred)  prefix=";" ;;
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
  # Optional state filter: 'deputy list --<state>' (e.g. --waiting, --running,
  # --deferred) lists only items in that state. Bare 'deputy list' lists all.
  local filter="" arg s
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --*)
        s="${arg#--}"
        if _valid_state "$s"; then filter="$s"; shift
        else printf 'deputy: list: unknown state filter: %s\n' "$arg" >&2; return 2; fi ;;
      *) printf 'deputy: list: unexpected argument: %s\n' "$arg" >&2; return 2 ;;
    esac
  done
  _with_lock _allocate_ids
  local raw parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    [[ -n "$filter" && "${parsed%%|*}" != "$filter" ]] && continue
    printf '%s\n' "$parsed"
  done < <(_each_item)
}

# Run a function while holding an exclusive lock on LOCK_FILE (short-held).
_with_lock() { ( flock -x 200; "$@" ) 200>"$LOCK_FILE"; }

_now_ms() {
  local n s
  n="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]{13,}$ ]]; then
    printf '%s' "$n"
    return 0
  fi
  s="$(date +%s)"
  printf '%s000' "$s"
}

_valid_positive_int() { [[ "${1:-}" =~ ^[0-9]+$ && "${1:-}" -gt 0 ]]; }

_epoch_ms() {
  local ts="${1:-}"
  if [[ "$ts" =~ ^[0-9]{13,}$ ]]; then
    printf '%s' "$ts"
  elif [[ "$ts" =~ ^[0-9]{10}$ ]]; then
    printf '%s000' "$ts"
  else
    return 1
  fi
}

_active_run_live() {
  local d="${1:-$ACTIVE_RUN_DIR}" pid recorded_start actual_start
  [[ -d "$d" ]] || return 1
  pid="$(sed -n '1p' "$d/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_start="$(sed -n '1p' "$d/start_time" 2>/dev/null || true)"
  if [[ -n "$recorded_start" ]]; then
    actual_start="$(_pid_start_time "$pid")"
    [[ "$actual_start" == "$recorded_start" ]] || return 1
  fi
  return 0
}

# True iff this process is an autonomous Deputy *worker* (the headless orchestrator
# spawned by cmd_run via _spawn_orchestrator), not an interactive human. Requires
# DEPUTY_GUARDED=1 AND a positive DEPUTY_ACTIVE_RUN_PID AND a LIVE active-run lock
# whose owning pid matches — so a stale exported env can never gate a human's add.
# (Compares the lock's pid file, not the owner file, which stores run/targeted.)
_is_worker_context() {
  [[ "${DEPUTY_GUARDED:-}" == "1" ]] || return 1
  local arp="${DEPUTY_ACTIVE_RUN_PID:-}"
  [[ "$arp" =~ ^[0-9]+$ ]] || return 1
  _active_run_live || return 1
  local lock_pid; lock_pid="$(sed -n '1p' "$ACTIVE_RUN_DIR/pid" 2>/dev/null || true)"
  [[ "$lock_pid" == "$arp" ]]
}

_active_run_summary() {
  local d="${1:-$ACTIVE_RUN_DIR}" pid owner item started
  pid="$(sed -n '1p' "$d/pid" 2>/dev/null || printf '?')"
  owner="$(sed -n '1p' "$d/owner" 2>/dev/null || printf '?')"
  item="$(sed -n '1p' "$d/item" 2>/dev/null || printf '?')"
  started="$(sed -n '1p' "$d/started_at" 2>/dev/null || printf '?')"
  printf 'owner=%s pid=%s started=%s item=%s' "$owner" "$pid" "$started" "$item"
}

_active_run_acquire() {
  local item="${1:-}" owner="${2:-run}"
  _do_active_run_acquire() {
    if [[ -e "$ACTIVE_RUN_DIR" ]]; then
      if _active_run_live "$ACTIVE_RUN_DIR"; then
        printf 'deputy: active run exists (%s) — skipping this tick.\n' "$(_active_run_summary "$ACTIVE_RUN_DIR")" >&2
        return 3
      fi
      rm -rf "$ACTIVE_RUN_DIR"
    fi
    mkdir "$ACTIVE_RUN_DIR" || return 1
    printf '%s\n' "$$" > "$ACTIVE_RUN_DIR/pid"
    printf '%s\n' "$(_pid_start_time "$$")" > "$ACTIVE_RUN_DIR/start_time"
    printf '%s\n' "$owner" > "$ACTIVE_RUN_DIR/owner"
    printf '%s\n' "$item" > "$ACTIVE_RUN_DIR/item"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$ACTIVE_RUN_DIR/started_at"
  }
  _with_lock _do_active_run_acquire
}

_active_run_release() {
  _do_active_run_release() {
    [[ -d "$ACTIVE_RUN_DIR" ]] || return 0
    local pid recorded_start actual_start
    pid="$(sed -n '1p' "$ACTIVE_RUN_DIR/pid" 2>/dev/null || true)"
    [[ "$pid" == "$$" ]] || return 0
    recorded_start="$(sed -n '1p' "$ACTIVE_RUN_DIR/start_time" 2>/dev/null || true)"
    if [[ -n "$recorded_start" ]]; then
      actual_start="$(_pid_start_time "$$")"
      [[ "$actual_start" == "$recorded_start" ]] || return 0
    fi
    rm -rf "$ACTIVE_RUN_DIR"
  }
  _with_lock _do_active_run_release
}

# Commit BACKLOG.md to git with a short reason message.
# Fails soft: a non-zero git exit never aborts the caller (deputy mutations must
# always succeed even when git is absent or the file is untracked).
# Must be called OUTSIDE the flock critical section (the file write is done first,
# the lock released, then we commit — matching the pattern in cmd_wp_commit).
_commit_queue() {
  local reason="${1:-queue update}"
  # Only act when inside a git work-tree.
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # Only act when BACKLOG.md is tracked by git.
  git -C "$ROOT" ls-files --error-unmatch -- BACKLOG.md >/dev/null 2>&1 || return 0
  # Only act when BACKLOG.md actually changed.
  git -C "$ROOT" diff --quiet -- BACKLOG.md && return 0
  # Commit ONLY BACKLOG.md — must not sweep other dirty files.
  git -C "$ROOT" add -- BACKLOG.md \
    && git -C "$ROOT" commit -q -m "chore(queue): $reason" -- BACKLOG.md \
    || true   # fail soft: never propagate a git error to the caller
}

# Create a temp file for a BACKLOG.md write.
# If the BACKLOG directory is writable, use it (same filesystem → mv is atomic).
# If not writable (bind-mount sandbox where only BACKLOG.md itself is rw), fall
# back to STATE_DIR — other failures (ENOSPC, quota) propagate as hard errors.
_backlog_mktemp() {
  local d; d="$(dirname "$BACKLOG")"
  if [[ -w "$d" ]]; then
    mktemp "$d/.backlog.tmp.XXXXXX"
  else
    mktemp "$STATE_DIR/.backlog.tmp.XXXXXX"
  fi
}

# Commit $1 (a temp file) into BACKLOG.md.
# When the BACKLOG directory is writable: mv is an atomic same-dir rename.
# When the directory is read-only (bind-mount sandbox where BACKLOG.md is rw):
#   fall back to an in-place truncating write, safe under _with_lock (flock).
#   A .bak copy is required before the write so a crash can be diagnosed.
_backlog_commit() {
  local tmp="$1"
  # Guard: tmp must be a non-empty (-s) regular file — prevents replacing
  # BACKLOG.md with truncated/empty output on I/O failure.
  [[ -n "$tmp" && -s "$tmp" && -f "$tmp" ]] || { rm -f "$tmp" 2>/dev/null; return 1; }
  local d; d="$(dirname "$BACKLOG")"
  if [[ -w "$d" ]]; then
    # Directory writable: atomic rename (always same filesystem, no partial copy risk).
    mv "$tmp" "$BACKLOG" 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
  # Directory not writable (bind-mount sandbox): use in-place write when BACKLOG.md
  # itself is writable; fail loudly for any other failure cause (ENOSPC etc.).
  if [[ -w "$BACKLOG" ]]; then
    local bak="${tmp}.bak"
    cp "$BACKLOG" "$bak" || { rm -f "$tmp"; return 1; }  # backup must succeed
    if cat "$tmp" > "$BACKLOG"; then
      rm -f "$tmp" "$bak" 2>/dev/null || true
      return 0
    fi
    [[ -s "$bak" ]] && cat "$bak" > "$BACKLOG" 2>/dev/null || true
    rm -f "$tmp" "$bak" 2>/dev/null || true
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Exact whole-line replacement (research.sh flip_line). Atomic via tmpfile+mv.
# Caller holds the lock. Used by upcoming set/claim commands.
_flip_line() {
  local from="$1" to="$2" tmp line _werr=0
  tmp="$(_backlog_mktemp)" || return 1
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$from" ]]; then printf '%s\n' "$to" || _werr=1; else printf '%s\n' "$line" || _werr=1; fi
  done < "$BACKLOG" > "$tmp" || _werr=1
  # A partial/ENOSPC write leaves a truncated-but-non-empty tmp that would pass
  # _backlog_commit's -s guard; fail the flip instead of committing it (#47).
  [[ "$_werr" -ne 0 ]] && { rm -f "$tmp" 2>/dev/null; return 1; }
  # One transaction: regroup sorts + commits the flipped temp to BACKLOG atomically.
  _regroup_backlog "$tmp"
}

# Append a raw line preceded by a blank line so items stay blank-separated.
# Append atomically through the same temp+commit path as every other write site:
# a raw '>> $BACKLOG' could leave a torn file on a partial write, and bypasses the
# read-only-dir handling (#73 sandbox: repo dir ro, BACKLOG rw). Caller holds the lock.
_append_item() {
  local tmp
  tmp="$(_backlog_mktemp)" || return 1
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  { cat "$BACKLOG" && printf '\n%s\n' "$1"; } > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  # One transaction: regroup sorts the staged (backlog + new line) temp and commits
  # it to BACKLOG once — no separate pre-commit, so no committed-but-unsorted window.
  _regroup_backlog "$tmp"
}

# Rewrite BACKLOG.md with items grouped by state: waiting first, active
# (triaging/running/surfaced/paused) next, terminal (done/failed/cancelled/
# duplicate) last. Each non-empty group is preceded by a blank line; items
# within a group are consecutive. No-ops if no '## Items' heading is found.
# Caller holds the lock.
_regroup_backlog() {
  # Read items from $1 (a mutator's staged temp) when given, else from BACKLOG in
  # place; always commit the regrouped result to BACKLOG in ONE commit. Routing a
  # mutation's staged temp through here makes "apply change + normalize" a single
  # transaction: the fully-sorted file lands or BACKLOG is untouched — never a
  # committed-but-unsorted middle state.
  local _src="${1:-$BACKLOG}"
  if ! grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$_src" 2>/dev/null; then
    # No '## Items' header to bucket under. In place: nothing to do. Given a staged
    # temp (legacy-format file), persist it verbatim so the mutation is never dropped.
    [[ "$_src" != "$BACKLOG" ]] && { _backlog_commit "$_src"; return $?; }
    return 0
  fi
  local tmp phase=header raw trimmed parsed state prio id desc rest norm
  # Seven buckets in display order; done_stream interleaves done items AND
  # release-delimiter lines (preserving their relative order). done_count tracks
  # ITEMS only (delimiters excluded from the Done header count).
  local -a running=() surfaced=() waiting=() paused=() deferred=() failcanc=() done_stream=()
  local done_count=0

  tmp="$(_backlog_mktemp)" || { [[ "$_src" != "$BACKLOG" ]] && rm -f "$_src" 2>/dev/null; return 1; }
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"

  # Single raw pass: copy the legend/header verbatim up to '## Items', then scan
  # the items area RAW (NOT _each_item, which hides delimiters). Drop blanks and
  # old '###' section headers (regenerated below); route release delimiters into
  # the Done stream; bucket items by state. A freshly-completed item sits above
  # the old Done block, so it is encountered first → lands at the TOP of Done.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    if [[ "$phase" == header ]]; then
      printf '%s\n' "$raw" >> "$tmp" || { rm -f "$tmp" 2>/dev/null; [[ "$_src" != "$BACKLOG" ]] && rm -f "$_src" 2>/dev/null; return 1; }
      [[ "$raw" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]] && phase=items
      continue
    fi
    [[ -z "${raw//[[:space:]]/}" ]] && continue                 # blank -> regenerated
    [[ "$raw" =~ ^[[:space:]]*##+[[:space:]] ]] && continue     # old '###' header -> drop
    trimmed="${raw#"${raw%%[![:space:]]*}"}"
    case "$trimmed" in '<!--'*) done_stream+=("$raw"); continue ;; esac  # delimiter -> Done
    _is_item_line "$raw" || continue                            # safety: skip non-items
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    rest="${parsed#*|}"; prio="${rest%%|*}"
    rest="${rest#*|}";   id="${rest%%|*}"
    desc="${rest#*|}"
    # Re-serialize each item so the canonical (current) symbols are written back —
    # this is what migrates pre-migration '#'/'>' lines to '+'/';' on regroup.
    norm="$(_serialize_item "$state" "$prio" "$id" "$desc")"
    case "$state" in
      running)                    running+=("$norm") ;;
      surfaced|triaging)          surfaced+=("$norm") ;;
      waiting)                    waiting+=("$norm") ;;
      paused)                     paused+=("$norm") ;;
      deferred)                   deferred+=("$norm") ;;
      failed|cancelled|duplicate) failcanc+=("$norm") ;;
      done)                       done_stream+=("$norm"); done_count=$((done_count + 1)) ;;
    esac
  done < "$_src"

  # When called from cmd_clean for done items, strip release delimiters that are
  # orphaned: no items appear between the delimiter and the next delimiter (or end).
  # Only real release delimiters are stripped — arbitrary HTML comments are kept.
  if [[ "${_REGROUP_STRIP_ORPHANED_DELIMS:-0}" -eq 1 && ${#done_stream[@]} -gt 0 ]]; then
    local -a _fds=()
    local _dsi _dsj _dsn=${#done_stream[@]} _dsh
    for (( _dsi=0; _dsi<_dsn; _dsi++ )); do
      if _is_release_delim_line "${done_stream[$_dsi]}"; then
        _dsh=0
        for (( _dsj=_dsi+1; _dsj<_dsn; _dsj++ )); do
          _is_release_delim_line "${done_stream[$_dsj]}" && break
          _is_item_line "${done_stream[$_dsj]}" && { _dsh=1; break; }
        done
        [[ "$_dsh" -eq 1 ]] && _fds+=("${done_stream[$_dsi]}")
      else
        _fds+=("${done_stream[$_dsi]}")
      fi
    done
    done_stream=("${_fds[@]}")
  fi

  # Always emit all seven '### Section (N)' headers, in order, for a stable
  # skeleton — even when a section is empty. Done is last (bottom of file).
  # Emit every section through ONE redirection and capture any partial-write
  # failure (e.g. ENOSPC). An unchecked printf here could leave a non-empty but
  # TRUNCATED tmp that still passes _backlog_commit's -s guard and then overwrites
  # BACKLOG.md with truncated content — the exact masked-truncation #47 targets.
  local _werr=0
  {
    printf '\n### Running (%d)\n' "${#running[@]}" || _werr=1
    (( ${#running[@]} )) && { printf '%s\n' "${running[@]}" || _werr=1; }
    printf '\n### Surfaced (%d)\n' "${#surfaced[@]}" || _werr=1
    (( ${#surfaced[@]} )) && { printf '%s\n' "${surfaced[@]}" || _werr=1; }
    printf '\n### Waiting (%d)\n' "${#waiting[@]}" || _werr=1
    (( ${#waiting[@]} )) && { printf '%s\n' "${waiting[@]}" || _werr=1; }
    printf '\n### Paused (%d)\n' "${#paused[@]}" || _werr=1
    (( ${#paused[@]} )) && { printf '%s\n' "${paused[@]}" || _werr=1; }
    printf '\n### Deferred (%d)\n' "${#deferred[@]}" || _werr=1
    (( ${#deferred[@]} )) && { printf '%s\n' "${deferred[@]}" || _werr=1; }
    printf '\n### Failed / Cancelled / Duplicate (%d)\n' "${#failcanc[@]}" || _werr=1
    (( ${#failcanc[@]} )) && { printf '%s\n' "${failcanc[@]}" || _werr=1; }
    printf '\n### Done (%d)\n' "$done_count" || _werr=1
    (( ${#done_stream[@]} )) && { printf '%s\n' "${done_stream[@]}" || _werr=1; }
    true   # keep the group's exit status tied to the redirect (open failure), not
           # to the trailing '(( count ))' test which is non-zero for an empty section
  } >> "$tmp" || _werr=1
  [[ "$_werr" -ne 0 ]] && { rm -f "$tmp" 2>/dev/null; [[ "$_src" != "$BACKLOG" ]] && rm -f "$_src" 2>/dev/null; return 1; }

  _backlog_commit "$tmp"; local _rc=$?
  [[ "$_src" != "$BACKLOG" ]] && rm -f "$_src" 2>/dev/null
  return "$_rc"
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
  tmp="$(_backlog_mktemp)" || return 1
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"

  # Rewrite the whole file, replacing un-id'd item lines in-place.
  local _ai_line _ai_seen=0 _ai_mode=none _werr=0
  if grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null; then _ai_mode=items
  elif grep -q -- '-->' "$BACKLOG" 2>/dev/null; then _ai_mode=comment
  fi
  while IFS= read -r _ai_line || [[ -n "$_ai_line" ]]; do
    # Copy header lines verbatim until the items section starts
    if [[ "$_ai_seen" -eq 0 && "$_ai_mode" != "none" ]]; then
      printf '%s\n' "$_ai_line" >> "$tmp" || _werr=1
      if [[ "$_ai_mode" == "items" && "$_ai_line" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]]; then _ai_seen=1; fi
      [[ "$_ai_mode" == "comment" && "$_ai_line" == *'-->'* ]] && _ai_seen=1
      continue
    fi
    # Preserve non-item lines verbatim (blanks, '###' section headers, release
    # delimiters) — they must never receive an ID or a priority tag.
    if ! _is_item_line "$_ai_line"; then
      printf '%s\n' "$_ai_line" >> "$tmp" || _werr=1; continue
    fi
    # Check if this item line needs an ID or a default priority
    parsed="$(_parse_item "$_ai_line")"
    _ai_id="${parsed#*|}"; _ai_id="${_ai_id#*|}"; _ai_id="${_ai_id%%|*}"
    if [[ -z "$_ai_id" ]]; then
      local _ai_state="${parsed%%|*}"
      local _ai_prio="${parsed#*|}"; _ai_prio="${_ai_prio%%|*}"
      local _ai_desc_rest="${parsed#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"
      # Items with no explicit priority get the default [P3] tag.
      [[ -z "$_ai_prio" ]] && _ai_prio="P3"
      local _ai_new_line
      _ai_new_line="$(_serialize_item "$_ai_state" "$_ai_prio" "$next_id" "$_ai_desc_rest")"
      printf '%s\n' "$_ai_new_line" >> "$tmp" || _werr=1
      next_id=$(( next_id + 1 ))
      changed=1
    else
      # Item already has an ID — backfill missing priority for legacy/manually-added lines.
      local _ai_state="${parsed%%|*}"
      local _ai_prio="${parsed#*|}"; _ai_prio="${_ai_prio%%|*}"
      local _ai_desc_rest="${parsed#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"
      if [[ -z "$_ai_prio" ]]; then
        local _ai_new_line
        _ai_new_line="$(_serialize_item "$_ai_state" "P3" "$_ai_id" "$_ai_desc_rest")"
        printf '%s\n' "$_ai_new_line" >> "$tmp" || _werr=1
        changed=1
      else
        printf '%s\n' "$_ai_line" >> "$tmp" || _werr=1
      fi
    fi
  done < "$BACKLOG"

  # A partial/ENOSPC write leaves a truncated-but-non-empty tmp that passes
  # _backlog_commit's -s guard; bail before committing it (#47).
  [[ "$_werr" -ne 0 ]] && { rm -f "$tmp" 2>/dev/null; return 1; }
  if [[ "$changed" -eq 1 ]]; then
    # One transaction: regroup sorts + commits the id-allocated temp to BACKLOG.
    _regroup_backlog "$tmp"
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

# Echo the next free item ID (max existing ID across ALL items + 1). Mirrors the
# max-scan in _allocate_ids. Callers must hold the queue lock when the value is used
# to serialize a new item, so it stays unique against concurrent adds.
_next_id() {
  [[ -f "$BACKLOG" ]] || { printf '1'; return 0; }
  local max_id=0 raw parsed _ni_id
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    _ni_id="${parsed#*|}"; _ni_id="${_ni_id#*|}"; _ni_id="${_ni_id%%|*}"
    [[ "$_ni_id" =~ ^[0-9]+$ && "$_ni_id" -gt "$max_id" ]] && max_id="$_ni_id"
  done < <(_each_item)
  printf '%s' "$(( max_id + 1 ))"
}

# #53: count surfaced items that genuinely BLOCK (a running item that flipped to
# surfaced because it needs human help) — EXCLUDING worker proposals, which are also
# 'surfaced' but carry a .deputy/proposed-<id> marker and must never stall scheduling
# or the cascade guard. A surfaced item with no id is counted as blocking (we cannot
# prove it is a proposal). Used in place of the raw cmd_status surfaced count.
_blocking_surfaced_count() {
  local n=0 raw parsed state _bs_rest _bs_id
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    [[ "$state" == "surfaced" ]] || continue
    _bs_rest="${parsed#*|}"; _bs_rest="${_bs_rest#*|}"; _bs_id="${_bs_rest%%|*}"
    if [[ "$_bs_id" =~ ^[0-9]+$ && ( -f "$STATE_DIR/proposed-$_bs_id" || -f "$STATE_DIR/ready-merge-$_bs_id" ) ]]; then
      continue   # a worker proposal (#53) or a ready-to-merge surface (#60) — not a blocking surface
    fi
    n=$(( n + 1 ))
  done < <(_each_item)
  printf '%s' "$n"
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
        --p3)       prio=P3; shift; continue ;;
        --p4)       prio=P4; shift; continue ;;
        -*) printf 'deputy: unknown flag: %s (use -- before a description starting with "-")\n' "$1" >&2; return 2 ;;
      esac
    fi
    text="${text}${text:+ }$1"
    shift
  done
  [[ -n "$text" ]] || { printf 'deputy: add requires text\n' >&2; return 2; }
  text="${text#"${text%%[![:space:]]*}"}"   # left-trim (matches parser's own trim)
  local _pfx="${text:0:1}"
  # Reject any leading status prefix — the new symbols (+ done, ; deferred) AND the
  # back-compat-read legacy ones (# done, > deferred), so a description can never be
  # silently re-bucketed/rewritten on regroup.
  if [[ "$_pfx" == '~' || "$_pfx" == '@' || "$_pfx" == '?' || "$_pfx" == '+' || \
        "$_pfx" == '!' || "$_pfx" == '%' || "$_pfx" == '=' || "$_pfx" == '^' || \
        "$_pfx" == ';' || "$_pfx" == '#' || "$_pfx" == '>' ]] || [[ "$text" =~ ^\[P[0-4]\] ]]; then
    printf 'deputy: description may not begin with a status prefix (~@?+!%%=^; legacy #>) or a [Px] tag: %s\n' "$text" >&2
    return 2
  fi
  if [[ "$text" == *$'\n'* ]]; then
    printf 'deputy: description may not contain a newline\n' >&2
    return 2
  fi
  # #53: a task added BY a worker (the headless orchestrator) is a *proposal* that
  # needs human approval — it must never auto-schedule itself. It lands 'surfaced'
  # (not waiting), drops a .deputy/proposed-<id> marker so it's distinguishable from
  # a blocked-item surface, skips the autorun, and notifies. Human/CLI adds are
  # unchanged. A per-invocation handoff file (.proposed_pending.$$) signals "a new
  # proposal was created" across the _with_lock subshell ($$ is stable across the
  # subshell) so the notify can fire after the lock — and concurrent adds, each with
  # a distinct $$, never erase each other's flag.
  local _worker=0
  _is_worker_context && _worker=1
  rm -f "$STATE_DIR/.proposed_pending.$$" 2>/dev/null || true
  _do_add() {
    _allocate_ids || return 1
    if _desc_exists "$text"; then
      printf 'deputy: already present: %s\n' "$text"; return 0
    fi
    if [[ "$_worker" -eq 1 ]]; then
      # Eagerly assign the id here (so the marker can name it), so _allocate_ids will
      # never revisit this line — meaning we must apply the P3 default now, exactly as
      # _allocate_ids would for an un-prioritized item.
      local _nid _pprio; _nid="$(_next_id)"; _pprio="${prio:-P3}"
      _append_item "$(_serialize_item surfaced "$_pprio" "$_nid" "$text")" || return 1
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      {
        printf 'proposed-by-run-pid: %s\n' "${DEPUTY_ACTIVE_RUN_PID:-}"
        printf 'proposed-at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'item: %s\n' "$(_serialize_item surfaced "$_pprio" "$_nid" "$text")"
        printf 'approve: deputy set "<line>" waiting\n'
        printf 'reject:  deputy set "<line>" cancelled\n'
      } > "$STATE_DIR/proposed-$_nid"
      printf '%s' "$_nid" > "$STATE_DIR/.proposed_pending.$$"
      printf 'deputy: proposed (awaiting human approval, #%s): %s\n' "$_nid" "$text"
      return 0
    fi
    _append_item "$(_serialize_item waiting "$prio" "" "$text")" || return 1
    printf 'deputy: added: %s\n' "$text"
  }
  local _add_rc=0
  _with_lock _do_add || _add_rc=$?
  # On a failed write, skip the commit + worker notify (no real change happened) and
  # report the failure; a dangling handoff marker is cleaned so it can't leak.
  if [[ "$_add_rc" -ne 0 ]]; then
    rm -f "$STATE_DIR/.proposed_pending.$$" 2>/dev/null || true
    return "$_add_rc"
  fi
  _commit_queue "add"
  if [[ "$_worker" -eq 1 ]]; then
    # A worker proposal never autoruns. Notify only if a NEW proposal was created
    # (the handoff file is absent on a duplicate, which returns early above).
    if [[ -s "$STATE_DIR/.proposed_pending.$$" ]]; then
      if [[ "${DEPUTY_NOTIFY_SYNC:-0}" == "1" ]]; then
        _notify proposed "$text" >/dev/null 2>&1 || true
      else
        _notify proposed "$text" >/dev/null 2>&1 &
      fi
    fi
    rm -f "$STATE_DIR/.proposed_pending.$$" 2>/dev/null || true
    return "$_add_rc"
  fi
  [[ "$_add_rc" -ne 0 ]] && return "$_add_rc"
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

# Numeric rank for a priority tag: P0=0 P1=1 P2=2 P3=3 P4=4 (none)=5.
_prio_rank() {
  case "$1" in P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; P3) echo 3 ;; P4) echo 4 ;; *) echo 5 ;; esac
}

# Print the remaining queue as an aligned table: waiting + paused (the runnable
# set cmd_pick draws from) grouped first, then deferred (inert — never auto-picked).
# Within each group: priority rank ascending, original file order preserved on ties
# (FIFO), matching cmd_pick. The header carries per-state counts. Prints a single
# "queue empty" line when no waiting/paused/deferred items remain. Called from
# cmd_set on the done-transition so every completion (interactive or autonomous)
# shows what's left.
_print_waiting_queue() {
  _with_lock _allocate_ids   # ensure every item has a stable [#N] before rendering
  local raw parsed state prio id desc rank grp idx=0
  local nw=0 npa=0 nd=0
  local -a rows=()
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    case "$state" in
      waiting)  grp=0; nw=$((nw+1)) ;;
      paused)   grp=0; npa=$((npa+1)) ;;
      deferred) grp=1; nd=$((nd+1)) ;;
      *)        idx=$((idx+1)); continue ;;
    esac
    prio="${parsed#*|}"; prio="${prio%%|*}"
    id="${parsed#*|}"; id="${id#*|}"; id="${id%%|*}"
    desc="${parsed#*|}"; desc="${desc#*|}"; desc="${desc#*|}"
    rank="$(_prio_rank "$prio")"
    [[ -n "$prio" ]] || prio="P?"
    [[ -n "$id" ]] || id="?"
    # truncate long descriptions so each row stays a single tidy line
    if [[ "${#desc}" -gt 80 ]]; then desc="${desc:0:79}…"; fi
    # group \t rank \t zero-padded file index \t STATE \t PRI \t #ID \t TASK
    rows+=("$(printf '%s\t%s\t%06d\t%s\t%s\t#%s\t%s' "$grp" "$rank" "$idx" "$state" "$prio" "$id" "$desc")")
    idx=$((idx+1))
  done < <(_each_item)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    printf 'Queue: empty (no waiting, paused, or deferred items).\n'
    return 0
  fi
  printf 'Queue — %d waiting, %d paused, %d deferred:\n' "$nw" "$npa" "$nd"
  printf '%-9s %-4s %-6s %s\n' 'STATE' 'PRI' 'ID' 'TASK'
  # sort by group (runnable<deferred), then rank, then file index (FIFO ties);
  # drop the 3 sort-key columns and render the remaining 4 as aligned columns.
  printf '%s\n' "${rows[@]}" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n \
    | cut -f4- \
    | while IFS="$(printf '\t')" read -r st pr id_col task; do
        printf '%-9s %-4s %-6s %s\n' "$st" "$pr" "$id_col" "$task"
      done
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
    proposed)  printf 'Worker proposed — approve?' ;;
    warn)      printf 'Warning' ;;
    spawn)     printf 'Autonomous spawn' ;;
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
  case "$state" in surfaced|proposed|warn|spawn|done|failed|cancelled|duplicate) ;; *) return 0 ;; esac
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
  [[ -n "$from" && -n "$newstate" ]] || { printf 'deputy: set requires "<line>|<id>" <state>\n' >&2; return 2; }
  # #60: --ready-merge marks a 'surfaced' item as "branch ready for human merge-review"
  # (distinct from a blocked surface) so it's excluded from the blocking-surfaced count.
  local _ready_merge=0 _a
  for _a in "${@:3}"; do          # flags only AFTER <line> <state> — never the line/desc itself
    case "$_a" in
      --ready-merge) _ready_merge=1 ;;
      *) printf 'deputy: set: unknown argument: %s\n' "$_a" >&2; return 2 ;;
    esac
  done
  _valid_state "$newstate" || { printf 'deputy: invalid state: %s\n' "$newstate" >&2; return 2; }
  # #56: accept an item id (N or #N) as the <line> arg, for parity with `run #N` /
  # `clean N`. Only when 'from' is NOT already a literal backlog line (whole-line form
  # always wins, so a legacy numeric raw line is unaffected) and looks like an id, resolve
  # it to THE line by parsed id field (robust vs description text that contains "[#N]").
  # Resolved here so the post-lock notify + marker-cleanup parse the real line; _do_set's
  # under-lock grep -qxF re-validates, so a line that moved meanwhile errors cleanly.
  if [[ "$from" =~ ^#?[0-9]+$ ]] && ! grep -qxF -- "$from" "$BACKLOG" 2>/dev/null; then
    local _want="${from#'#'}" _raw _p _rid _n=0 _hit=""
    while IFS= read -r _raw; do
      _p="$(_parse_item "$_raw")"; _rid="${_p#*|}"; _rid="${_rid#*|}"; _rid="${_rid%%|*}"
      [[ "$_rid" == "$_want" ]] && { _n=$((_n + 1)); _hit="$_raw"; }
    done < <(_each_item)
    [[ "$_n" -eq 0 ]] && { printf 'deputy: set: no item with id #%s\n' "$_want" >&2; return 2; }
    [[ "$_n" -gt 1 ]] && { printf 'deputy: set: multiple items with id #%s — pass the exact line instead\n' "$_want" >&2; return 2; }
    from="$_hit"
  fi
  _do_set() {
    grep -qxF -- "$from" "$BACKLOG" || return 1     # exact-line existence
    local parsed prio desc to _id_rest _id
    parsed="$(_parse_item "$from")"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    _id_rest="${parsed#*|}"; _id_rest="${_id_rest#*|}"; _id="${_id_rest%%|*}"
    desc="${_id_rest#*|}"
    to="$(_serialize_item "$newstate" "$prio" "$_id" "$desc")"
    # Propagate a write failure: a swallowed rc here would let the trailing #60 marker
    # block (which returns 0) mask a failed line flip, so 'set' would falsely report success.
    _flip_line "$from" "$to" || return 1
    # #60: maintain the ready-merge marker under the SAME lock as the line flip, so scheduling
    # never sees a 'surfaced' item without its marker (no blocking-count race window).
    if [[ "$_id" =~ ^[0-9]+$ ]]; then
      if [[ "$newstate" == "surfaced" && "$_ready_merge" == "1" ]]; then
        printf 'ready-merge-at: %s\nbranch ready for human merge-review\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/ready-merge-$_id" 2>/dev/null || true
      elif [[ "$newstate" != "surfaced" ]]; then
        rm -f "$STATE_DIR/ready-merge-$_id" 2>/dev/null || true
      fi
    fi
  }
  local _set_rc=0
  _with_lock _do_set || _set_rc=$?
  if [[ "$_set_rc" -eq 0 ]]; then
    _commit_queue "set $newstate"
    local _parsed _desc _id_rest2
    _parsed="$(_parse_item "$from")"
    _id_rest2="${_parsed#*|}"; _id_rest2="${_id_rest2#*|}"; _desc="${_id_rest2#*|}"
    # #53: once a proposal (surfaced) is approved (->waiting), rejected (->cancelled),
    # or otherwise leaves surfaced, its .deputy/proposed-<id> marker is obsolete. The
    # rm is a no-op for non-proposal items (no marker). Skip while staying surfaced.
    if [[ "$newstate" != "surfaced" ]]; then
      local _ps_id="${_id_rest2%%|*}"
      [[ "$_ps_id" =~ ^[0-9]+$ ]] && rm -f "$STATE_DIR/proposed-$_ps_id" 2>/dev/null || true
    fi
    # Background by default so slow channels (e.g. push/curl) don't block the CLI.
    # Set DEPUTY_NOTIFY_SYNC=1 to run synchronously (used in tests).
    if [[ "${DEPUTY_NOTIFY_SYNC:-0}" == "1" ]]; then
      _notify "$newstate" "$_desc" >/dev/null 2>&1 || true
    else
      _notify "$newstate" "$_desc" >/dev/null 2>&1 &
    fi
    # On a completion, show what's left. Done-only by design: a task is "completed"
    # only when done — failures (which transition via internal _do_set_item_failed,
    # not cmd_set) intentionally do not print the queue. In autonomous runs the
    # orchestrator's `deputy set <line> done` stdout is captured + relayed by the
    # run loop, so this single call covers both interactive and autonomous paths.
    if [[ "$newstate" == "done" ]]; then
      _print_waiting_queue
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

# True (0) if a live interactive Claude Code session is active in this repo.
# Reads ~/.claude/sessions/*.json; each file represents one Claude process.
# We back off only for entrypoint=="cli" sessions (human-driven), not "sdk-cli"
# (headless deputy invocations). Path comparison is done after realpath normalization.
#
# Dead-PID session files that match this repo are a sign of an abnormal Claude crash.
# When found, the stale PID is recorded in the caller-supplied _isa_stale_pid variable
# (first one wins) and scanning continues — a live session still takes precedence.
# The surface-vs-proceed decision is made by cmd_run, not here.
#
# Returns 0 (true/match) and sets _isa_pid to the matched PID when a live session
# is found; returns 1 (and possibly sets _isa_stale_pid) when no live session exists.
_interactive_session_active() {
  local repo_root="${1:-$ROOT}"
  # Normalize repo root once (handles symlinks, trailing slashes).
  local norm_root; norm_root="$(realpath "$repo_root" 2>/dev/null || readlink -f "$repo_root" 2>/dev/null || printf '%s' "$repo_root")"
  local sessions_dir="$HOME/.claude/sessions"

  if [[ ! -d "$sessions_dir" ]] || ! command -v jq >/dev/null 2>&1; then
    # Fallback: scan live claude processes via /proc when sessions dir or jq absent.
    local pid pcwd norm_pcwd
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      [[ "$pid" == "$$" ]] && continue
      pcwd="$(readlink /proc/"$pid"/cwd 2>/dev/null || true)"
      [[ -n "$pcwd" ]] || continue
      norm_pcwd="$(realpath "$pcwd" 2>/dev/null || readlink -f "$pcwd" 2>/dev/null || printf '%s' "$pcwd")"
      if [[ "$norm_pcwd" == "$norm_root" || "$norm_pcwd" == "$norm_root/"* ]]; then
        _isa_pid="$pid"
        return 0
      fi
    done < <(pgrep -x claude 2>/dev/null || true)
    return 1
  fi

  local f fields pid cwd entrypoint procstart status status_updated_at norm_cwd stat_start
  for f in "$sessions_dir"/*.json; do
    [[ -f "$f" ]] || continue
    # Extract all needed fields in one jq call (avoids per-field subshell cost).
    fields="$(jq -r '[.pid // "", .cwd // "", .entrypoint // "", .procStart // "", .status // "", (.statusUpdatedAt // .updatedAt // "")] | @tsv' "$f" 2>/dev/null)" || continue
    IFS=$'\t' read -r pid cwd entrypoint procstart status status_updated_at <<< "$fields"

    # Only interactive CLI sessions — not sdk-cli (deputy/headless invocations).
    [[ "$entrypoint" == "cli" ]] || continue

    # Normalize cwd and check repo membership.
    norm_cwd="$(realpath "$cwd" 2>/dev/null || readlink -f "$cwd" 2>/dev/null || printf '%s' "$cwd")"
    [[ "$norm_cwd" == "$norm_root" || "$norm_cwd" == "$norm_root/"* ]] || continue

    # PID must be a valid integer.
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue

    # Liveness check.
    if ! kill -0 "$pid" 2>/dev/null; then
      # Dead PID in this repo — record the stale pid for potential surfacing.
      # Do NOT delete Claude's session file. A live session still takes precedence.
      [[ -z "$_isa_stale_pid" ]] && _isa_stale_pid="$pid"
      continue
    fi

    # procStart validation: prevents false positives from PID recycling.
    # Claude stores /proc/<pid>/stat field 22 (start time in clock ticks since boot).
    # /proc/stat field 2 is the process name wrapped in parentheses and may contain
    # spaces; strip everything through the last ')' before counting fields so the
    # start-time is always at position 22 regardless of the process name.
    if [[ -n "$procstart" ]]; then
      stat_start="$(sed 's/.*) //' /proc/"$pid"/stat 2>/dev/null | awk '{print $20}' || true)"
      if [[ -n "$stat_start" && "$stat_start" != "$procstart" ]]; then
        # PID was recycled — this session file is stale.
        [[ -z "$_isa_stale_pid" ]] && _isa_stale_pid="$pid"
        continue
      fi
    fi

    _isa_pid="$pid"
    _isa_status="$status"
    _isa_status_updated_at="$status_updated_at"
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
    # Abort before writing the claim file if the BACKLOG transition failed, so a
    # failed write can't leave a live claim pointing at a never-transitioned line.
    _flip_line "$from" "$to" || return 1
    # Write claim file: line 1 = running item line; line 2 = PID start-time for liveness validation.
    local _claim_start; _claim_start="$(_pid_start_time "$pid")"
    if ! printf '%s\n%s\n' "$to" "$_claim_start" > "$STATE_DIR/$pid.claim"; then
      # Claim-file write failed after the flip: roll the line back to waiting so we
      # don't leave a claimless 'running' item (best-effort; orphan recovery is the
      # backstop if this rollback write also fails).
      _revert_to_waiting "$to" || true
      rm -f "$STATE_DIR/$pid.claim" 2>/dev/null || true
      return 1
    fi
  }
  local _claim_rc=0; _with_lock _do_claim || _claim_rc=$?
  [[ "$_claim_rc" -eq 0 ]] && _commit_queue "claim running"
  return "$_claim_rc"
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
        # Revert the stale claim's line to waiting BEFORE dropping the claim file; if
        # that write fails, keep the claim file so recovery can retry rather than
        # orphaning a 'running' line with no claim record.
        [[ -n "$line" ]] && { _revert_to_waiting "$line" || return 1; }
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
      [[ "$found" -eq 0 ]] && { _revert_to_waiting "$raw" || return 1; }
    done < <(_each_item)
  }
  local _rec_rc=0; _with_lock _do_recover || _rec_rc=$?
  [[ "$_rec_rc" -eq 0 ]] && _commit_queue "recover"
  return "$_rec_rc"
}

cmd_review() { cmd_reflect "$@"; }

# Print the installed deputy version (the VERSION file shipped alongside the script).
# Resolves relative to the real script location (SRC_DIR), so it is correct even when
# `deputy` is invoked via the PATH symlink from another repo.
cmd_version() {
  local vf="$SRC_DIR/VERSION" v
  if [[ -r "$vf" ]] && v="$(tr -d '[:space:]' < "$vf")" && [[ -n "$v" ]]; then
    printf 'deputy %s\n' "$v"
  else
    printf 'deputy: version unknown (VERSION file not found at %s)\n' "$vf" >&2
    return 1
  fi
}

# Mark a release boundary in the Done section. Inserts a parser-safe delimiter
# (`<!-- release v<ver> — <date> -->`) at the TOP of Done. Completed tasks
# accumulate above the most-recent delimiter (the unreleased set); running
# `deputy release` draws the line under them. Version defaults to the PROJECT's
# VERSION file ($ROOT/VERSION); pass an explicit version to override. Idempotent:
# a no-op if that exact delimiter (version + today's date) already exists.
cmd_release() {
  local ver="${1:-}"
  if [[ -z "$ver" && -r "$ROOT/VERSION" ]]; then
    # read -r (default IFS) trims leading/trailing whitespace but preserves any
    # INTERNAL whitespace, so a malformed 'VERSION' like '1.0 beta' is caught by
    # the validation below instead of being silently squashed to '1.0beta'.
    read -r ver < "$ROOT/VERSION" || ver=""
  fi
  ver="${ver#[vV]}"                 # normalize a single leading v/V
  # Reject anything that would break the HTML comment or the one-line format
  # ('--' terminates an HTML comment; '<'/'>' and whitespace are unsafe).
  if [[ -z "$ver" || "$ver" == *[[:space:]]* || "$ver" == *"<"* || "$ver" == *">"* || "$ver" == *"--"* ]]; then
    printf 'deputy: release requires a clean version; pass one explicitly or set %s/VERSION\n' "$ROOT" >&2
    return 2
  fi
  grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null || {
    printf 'deputy: release: no "## Items" section in %s\n' "$BACKLOG" >&2; return 1; }
  local delim; delim="<!-- release v$ver — $(date +%Y-%m-%d) -->"
  # The authoritative idempotency check + insert run TOGETHER under the lock so two
  # concurrent releases can't both insert the same marker. _do_release returns 3
  # (sentinel) when the marker already exists.
  _do_release() {
    _regroup_backlog                 # ensure the sectioned layout / '### Done' header exists
    grep -qxF -- "$delim" "$BACKLOG" 2>/dev/null && return 3   # already present
    local tmp; tmp="$(_backlog_mktemp)" || return 1
    chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    # Insert the delimiter immediately after the '### Done (N)' header line.
    # Explicitly check the write path: _with_lock invokes us under '|| rrc=$?',
    # which suppresses set -e here, so an unchecked awk/commit failure could replace
    # the backlog with partial/empty output and still report success.
    awk -v d="$delim" '{ print } /^### Done / && !seen { print d; seen=1 }' "$BACKLOG" > "$tmp" \
      || { rm -f "$tmp"; return 1; }
    # One transaction: regroup sorts + commits the delimiter-inserted temp to BACKLOG
    # (it preserves the release delimiter at the top of Done).
    _regroup_backlog "$tmp" || return 1
  }
  local rrc=0; _with_lock _do_release || rrc=$?
  if [[ "$rrc" -eq 3 ]]; then
    printf 'deputy: release marker already present: %s\n' "$delim"
    return 0
  elif [[ "$rrc" -ne 0 ]]; then
    printf 'deputy: release failed (exit %s)\n' "$rrc" >&2
    return 1
  fi
  _commit_queue "release v$ver"      # commit AFTER the lock is released
  printf 'deputy: release marker added: %s\n' "$delim"
}

# Print done items above the most-recent release delimiter in BACKLOG.md, one bullet
# per item, ready to paste into CHANGELOG. Read-only: no writes, no ID allocation.
# If no release delimiter exists, all done items are printed.
# Exits 0 (with bullet list or 'No unreleased items.'); exits 1 if BACKLOG.md missing.
cmd_release_notes() {
  [[ -f "$BACKLOG" ]] || { printf 'deputy: release-notes: %s not found\n' "$BACKLOG" >&2; return 1; }
  local -a results=()
  local line parsed state prio id desc rest
  # Sectioned path: scan raw file after '### Done' header, stop at first delimiter.
  # Legacy fallback: if no '### Done' header exists, iterate all done items via
  # _each_item (no delimiter can exist without a header, so all done items qualify).
  if grep -qE '^### Done' "$BACKLOG" 2>/dev/null; then
    local in_done=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$in_done" -eq 0 ]]; then
        [[ "$line" =~ ^###[[:space:]]+Done ]] && in_done=1
        continue
      fi
      [[ "$line" == '<!-- release v'* ]] && break  # most-recent delimiter: stop here
      [[ "$line" =~ ^###[[:space:]] ]] && break    # next section header: layout safety
      _is_item_line "$line" || continue
      parsed="$(_parse_item "$line")"
      state="${parsed%%|*}"; [[ "$state" == done ]] || continue
      rest="${parsed#*|}"; prio="${rest%%|*}"; rest="${rest#*|}"; id="${rest%%|*}"; desc="${rest#*|}"
      if [[ -n "$id" ]]; then results+=("- [#${id}] ${desc}"); else results+=("- ${desc}"); fi
    done < "$BACKLOG"
  else
    # Legacy backlog without section headers: all done items qualify (no delimiters exist).
    while IFS= read -r line; do
      parsed="$(_parse_item "$line")"
      state="${parsed%%|*}"; [[ "$state" == done ]] || continue
      rest="${parsed#*|}"; prio="${rest%%|*}"; rest="${rest#*|}"; id="${rest%%|*}"; desc="${rest#*|}"
      if [[ -n "$id" ]]; then results+=("- [#${id}] ${desc}"); else results+=("- ${desc}"); fi
    done < <(_each_item)
  fi
  if [[ ${#results[@]} -eq 0 ]]; then
    printf 'No unreleased items.\n'
  else
    printf '%s\n' "${results[@]}"
  fi
}

# Append-only xReview audit trail. Reads the review-iteration record from stdin and
# appends it to .deputy/<slug>.review.md (deputy's equivalent of xReview's
# .review/REVIEW.md). NEVER overwrites — always appends, with a blank-line separator.
# The slug must be a single path component (no slashes / '..') so the write stays in
# .deputy/, matching the guardrail allowlist.
cmd_review_log() {
  local slug="${1:-}"
  if [[ -z "$slug" ]]; then
    printf 'deputy: review-log requires <slug> (record read from stdin)\n' >&2; return 2
  fi
  case "$slug" in
    */*|..|.) printf 'deputy: review-log: invalid slug %s%s%s (no slashes)\n' "'" "$slug" "'" >&2; return 2 ;;
  esac
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local f="$STATE_DIR/$slug.review.md"
  # Seed a header the first time so the file is self-describing.
  [[ -s "$f" ]] || printf '# xReview trail — %s\n' "$slug" >> "$f"
  printf '\n' >> "$f"
  cat >> "$f"
  printf '\n' >> "$f"
}

usage() {
  cat <<'EOF'
usage: deputy <command> [args]

commands:
  add "<text>" [-ui|-u|-i]        add a waiting item and run it immediately if idle
                                  (-ui=P0 -u=P1 -i=P2; --p0/--p1/--p2/--p3/--p4 also accepted;
                                  no flag → default priority P3 assigned at numbering;
                                  use -- before a description that starts with "-";
                                  set DEPUTY_NO_AUTORUN=1 to enqueue without running)
  list [--<state>]                print parsed items (state|priority|id|description);
                                  optional --<state> (e.g. --waiting, --running, --deferred)
                                  lists only items in that state
  status                          counts by state
  watch                           live-tail the currently-running worker's output (any terminal; Ctrl-C detaches)
  run [<id>] [--once] [--headless] work the backlog: claim the top item, run the orchestrator
                                  (interactive/TTY runs stream output live; --headless or
                                  headed=0 config forces the buffered/cron behavior)
                                  if <id> given (integer; '#7' also accepted), run that
                                  specific item bypassing priority order (targeted, one item only)
  set "<exact line>"|<id> <state> transition an item's state — by exact-line match, or by
                                  item id (e.g. `deputy set 50 waiting` / `set #50 waiting`)
  cron --ensure|--remove|--reschedule "<text>"   manage the safety-net schedule
  clean [<id>] [--dry-run] [--state <state>]
                                  remove items matching the filter:
                                    <id>           clean one item by its numeric ID (e.g. '7' or '#7')
                                    --state <s>    remove all items of <state> (default: waiting)
                                  cleanable states: waiting, done, failed, cancelled, duplicate, deferred
                                  refuses running, triaging, surfaced, paused (active/checkpointed/awaiting)
  reflect [--apply]               full queue health report: learnings, untagged items, reprioritization
                                  list, surfaced items + question files, duplicate candidates, status
                                  digest; --apply writes .deputy/learnings.md
                                  (alias: review)
  release [version]               mark a release boundary in Done: insert a dated
                                  `<!-- release vX — YYYY-MM-DD -->` delimiter at the top
                                  of the Done section (version defaults to ./VERSION)
  release-notes                   print Done items above the most-recent release delimiter
                                  as a CHANGELOG-ready bullet list (done-since-last-release);
                                  if no delimiter exists, prints all Done items
  version                         print the installed deputy version (also --version, -V)
  help                            show this message

config keys (.deputy/config):
  max_items=N                     items started per run cycle (default 1; min 1). MIGRATION: 0 no longer means unlimited — it clamps to 1; set an explicit N for a multi-item drain
  heartbeat_mins=N                cron heartbeat interval in minutes (default 10; 1–59)
  human_backoff=1                 back off when an interactive Claude session is busy/recent in this repo (default 1; set 0 to disable)
  human_idle_grace_mins=N         allow cron to run when Claude has been idle this many minutes (default 5)
  waiting_backoff_strikes=N       consecutive 'waiting' heartbeat ticks required before cron proceeds (default 3)
  orphan_warn_mins=N              warn (never kill) about a bash orphan running > this many minutes under an in-repo Claude session (default 30)
  auto_merge=1                    allow a spawned (headless) worker to git-merge its branch to the default branch; default 0 = the guardrail blocks the merge and the worker must surface the branch for human review
  notify_on_spawn=0               silence the notification + cron.log '===SPAWN===' line emitted when the heartbeat autonomously spawns a worker; default 1 = announce every autonomous pickup (never silent)
  sandbox=0                       disable the bwrap read-only sandbox around the headless worker (default 1 = repo code is OS-read-only to the worker, only .deputy/+BACKLOG.md+worktree writable); 0 falls back to cwd-pinning only
  auto_mode=1                     when xReview has no peer reviewer (both Codex+Gemini down), self-review with a warning and proceed; default 0 = surface the item for the user instead
  notify=desktop,push,email       channels for item-surfaced/finished notifications
  notify_push_url=<url>           ntfy.sh-compatible push URL (required for push)
  notify_email=<address>          recipient address (required for email)
states: waiting triaging running surfaced done failed cancelled duplicate paused deferred
symbols: (none)=waiting ~=triaging @=running ?=surfaced +=done !=failed %=cancelled ==duplicate ^=paused ;=deferred  (legacy #=done >=deferred still read and auto-migrated)
EOF
}

# Classify a CLI invocation outcome: ok|quota_exhausted|auth_error|hard_error.
# Conservative: an unrecognized non-zero exit is hard_error, never quota_exhausted.
_detect_outcome() {
  local cli="$1" rc="$2" log="$3" content="" rl=""
  [[ -f "$log" ]] && content="$(cat "$log")"
  # #66: a claude stream-json run can exit rc=0 even on a model-side error — the verdict is
  # the final 'result' event's is_error, not the exit code. Dual-mode: if the log carries a
  # stream-json result event, trust is_error (+ rc); otherwise (plain-text / mock / other
  # CLI) fall back to the original rc check. Either way, classify failures from the log text.
  rl="$(printf '%s' "$content" | grep -F '"type":"result"' | tail -1 || true)"
  if [[ -n "$rl" ]]; then
    [[ "$rc" -eq 0 && "$rl" != *'"is_error":true'* ]] && { printf 'ok\n'; return 0; }
  else
    [[ "$rc" -eq 0 ]] && { printf 'ok\n'; return 0; }
  fi
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
# Echoes: a provider name | "self" (review: only the author is left) |
#         "wait" (claude-bound work down / no reviewer at all) | "none".
#
# review routing is AUTHOR-AWARE and mirrors xReview's codex>gemini>peer>self chain:
#   $3 = author (the provider that wrote the diff under review; may be empty).
#   Codex is the DEFAULT reviewer; Gemini and Claude are fallbacks. The author is
#   never offered as a reviewer (author != reviewer) until it is the only one left,
#   in which case "self" is echoed so the caller can degrade per mode (auto =>
#   self-review with a warning; interactive => surface). This removes the old
#   Gemini-only deadlock: review no longer bare-"wait"s while a peer is available.
_route() {
  local kind="$1" avail="$2" author="${3:-}" cand
  case "$kind" in
    orchestrate|code-complex)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      printf 'wait\n' ;;
    code-simple)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      _in_csv codex  "$avail" && { printf 'codex\n';  return 0; }
      printf 'wait\n' ;;
    review)
      # Pick a non-author peer, AUTHOR-AWARE (preference depends on who wrote the
      # artifact). claude is the orchestrator, so it self-reviews only as a last
      # resort — it is never the *first* choice when it is the author, and it is not
      # an eligible reviewer at all when no author is named (an unnamed author is
      # claude by convention, so offering claude would risk reviewing its own work).
      #   author=claude -> codex, gemini          (external peers; codex preferred)
      #   author=codex  -> claude, gemini         (claude-first; gemini is flaky)
      #   author=gemini -> claude, codex          (claude-first)
      #   author=''     -> codex, gemini          (no claude self-review)
      local candidates
      case "$author" in
        claude) candidates="codex gemini" ;;
        codex)  candidates="claude gemini" ;;
        gemini) candidates="claude codex" ;;
        "")     candidates="codex gemini" ;;
        *)      candidates="codex gemini claude" ;;   # unknown author: full peer set
      esac
      for cand in $candidates; do
        [[ "$cand" == "$author" ]] && continue        # safety: never the author
        _in_csv "$cand" "$avail" && { printf '%s\n' "$cand"; return 0; }
      done
      # No non-author peer available. If only the author is up, signal self-review.
      if [[ -n "$author" ]] && _in_csv "$author" "$avail"; then
        printf 'self\n'; return 0
      fi
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

# Evaluate the human-session back-off gate. Reads config, calls
# _interactive_session_active, performs the side-effect (stderr message or stale
# surface), and returns:
#   0 → deputy should STOP this tick (live session detected, or stale handled)
#   1 → deputy should PROCEED (no session, old idle session, or human_backoff=0)
#
# Callers must declare `local _isa_pid="" _isa_status="" _isa_status_updated_at=""
# _isa_stale_pid=""` in their own scope before calling (the function uses those
# upvar names).
# #55: durable consecutive-'waiting' strike counter for the human back-off gate.
# The undocumented 'waiting' session status can mean idle-at-prompt — but we can't be
# sure it isn't a transient mid-tool pause, so instead of trusting it we require it to
# PERSIST across N consecutive heartbeat ticks before proceeding. The counter file holds
# 'pid|statusUpdatedAt|count|last_bump_ms'; _with_lock serializes the read-increment-write
# so overlapping ticks can't race it. A transient 'waiting' can't survive N ticks (any
# status flip changes statusUpdatedAt -> reset), so N-in-a-row implies genuine idle.
_bump_locked() {
  local pid="$1" sua="$2" f="$STATE_DIR/.backoff_waiting" now hb min_gap
  local cur_pid="" cur_sua="" cur_cnt=0 cur_last=0 cnt tmp
  now="$(_now_ms)"
  hb="$(_config_get heartbeat_mins)"; hb="${hb:-10}"; _valid_positive_int "$hb" || hb=10
  min_gap=$(( hb * 60 * 1000 / 2 )); [[ "$min_gap" -ge 1 ]] || min_gap=30000
  if [[ -f "$f" ]]; then IFS='|' read -r cur_pid cur_sua cur_cnt cur_last < "$f"; fi
  [[ "$cur_cnt" =~ ^[0-9]+$ ]] || cur_cnt=0
  if [[ "$cur_pid" == "$pid" && "$cur_sua" == "$sua" ]]; then
    # Same continuous 'waiting'. Increment only when this bump is >= half a heartbeat
    # since the last, so overlapping ticks / an add-instant-trigger race collapse to one
    # strike. A future/malformed last_bump_ms (now < cur_last) falls through to increment.
    if [[ "$now" =~ ^[0-9]+$ && "$cur_last" =~ ^[0-9]+$ && "$now" -ge "$cur_last" \
          && $(( now - cur_last )) -lt "$min_gap" ]]; then
      cnt="$cur_cnt"
    else
      cnt=$(( cur_cnt + 1 ))
    fi
  else
    cnt=1   # new / changed session or fresh 'waiting' -> first strike
  fi
  tmp="$(mktemp "$STATE_DIR/.backoff_waiting.XXXXXX" 2>/dev/null)" || tmp="$f.$$"
  if printf '%s|%s|%s|%s\n' "$pid" "$sua" "$cnt" "$now" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  printf '%s' "$cnt"
}
_backoff_waiting_bump()  { _with_lock _bump_locked "$1" "$2"; }
_backoff_waiting_reset() { _with_lock rm -f "$STATE_DIR/.backoff_waiting" 2>/dev/null; return 0; }

# #57 (Part B): echo (one per line) the PIDs of LIVE interactive cli Claude sessions whose
# cwd is in $1 (default $ROOT), validated by procStart (PID-recycle guard) — same checks as
# _interactive_session_active, but ALL of them. Anchors the stale-orphan scan to real Claude
# sessions, never a generic repo-cwd process sweep (which would flag legit user shells).
_inrepo_session_pids() {
  local repo_root="${1:-$ROOT}" norm_root sessions_dir f fields pid cwd entrypoint procstart norm_cwd stat_start
  norm_root="$(realpath "$repo_root" 2>/dev/null || readlink -f "$repo_root" 2>/dev/null || printf '%s' "$repo_root")"
  sessions_dir="$HOME/.claude/sessions"
  { [[ -d "$sessions_dir" ]] && command -v jq >/dev/null 2>&1; } || return 0
  for f in "$sessions_dir"/*.json; do
    [[ -f "$f" ]] || continue
    fields="$(jq -r '[.pid // "", .cwd // "", .entrypoint // "", .procStart // ""] | @tsv' "$f" 2>/dev/null)" || continue
    IFS=$'\t' read -r pid cwd entrypoint procstart <<< "$fields"
    [[ "$entrypoint" == "cli" && "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    norm_cwd="$(realpath "$cwd" 2>/dev/null || readlink -f "$cwd" 2>/dev/null || printf '%s' "$cwd")"
    [[ "$norm_cwd" == "$norm_root" || "$norm_cwd" == "$norm_root/"* ]] || continue
    if [[ -n "$procstart" ]]; then
      stat_start="$(sed 's/.*) //' /proc/"$pid"/stat 2>/dev/null | awk '{print $20}' || true)"
      [[ -n "$stat_start" && "$stat_start" != "$procstart" ]] && continue
    fi
    printf '%s\n' "$pid"
  done
}

# #57 (Part B): WARN-ONLY stale-orphan detection. For each live in-repo cli Claude session,
# walk its process descendants and warn (stderr/cron.log + notify) about any `bash` process
# running longer than orphan_warn_mins (config, default 30) — a likely leaked background
# command (e.g. a hung `until…sleep` review-wait) that pins the session non-idle and stalls
# the heartbeat. NEVER kills (that's a human judgment call); just surfaces a `kill <pid>`
# hint. Per-PID throttled via .deputy/.orphan_warned so the heartbeat doesn't re-notify
# every tick. Best-effort: silently no-ops without ps/proc.
_warn_stale_orphans() {
  command -v ps >/dev/null 2>&1 || return 0
  local _owm; _owm="$(_config_get orphan_warn_mins)"; _owm="${_owm:-30}"
  [[ "$_owm" =~ ^[0-9]+$ ]] || _owm=30   # non-negative; 0 = warn about all orphans (noisy)
  local roots; roots="$(_inrepo_session_pids)"; [[ -n "$roots" ]] || return 0
  # Build pid -> "ppid comm etimes" once.
  local snap; snap="$(ps -eo pid=,ppid=,comm=,etimes= 2>/dev/null)" || return 0
  local thresh=$(( _owm * 60 )) now; now="$(_now_ms)"
  # BFS descendants of each root; collect bash pids older than the threshold.
  local -a queue=() ; local r; while IFS= read -r r; do [[ "$r" =~ ^[0-9]+$ ]] && queue+=("$r"); done <<< "$roots"
  local -A seen=() ; local -a stale=()
  local cur line p pp comm et
  while [[ "${#queue[@]}" -gt 0 ]]; do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    [[ -n "${seen[$cur]:-}" ]] && continue; seen[$cur]=1
    while IFS= read -r line; do
      read -r p pp comm et <<< "$line"
      [[ "$pp" == "$cur" ]] || continue
      queue+=("$p")
      if [[ "$comm" == "bash" && "$et" =~ ^[0-9]+$ && "$et" -gt "$thresh" ]]; then stale+=("$p|$et"); fi
    done <<< "$snap"
  done
  local wf="$STATE_DIR/.orphan_warned"
  if [[ "${#stale[@]}" -eq 0 ]]; then rm -f "$wf" 2>/dev/null; return 0; fi
  local _owt=$(( _owm < 1 ? 1 : _owm )) throttle prior="" newf="" ent spid s_et last
  throttle=$(( _owt * 60 * 1000 ))   # re-warn window (>= 1 min, so the heartbeat doesn't spam)
  [[ -f "$wf" ]] && prior="$(cat "$wf" 2>/dev/null)"
  for ent in "${stale[@]}"; do
    spid="${ent%%|*}"; s_et="${ent#*|}"
    last="$(printf '%s\n' "$prior" | awk -F'|' -v p="$spid" '$1==p{print $2}' | head -1)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$now" =~ ^[0-9]+$ && $(( now - last )) -ge "$throttle" ]]; then
      printf 'deputy: WARNING — orphaned process pid %s (a bash command running %sm under an interactive Claude session in %s) may be pinning the session busy and stalling the heartbeat; investigate and, if dead weight, run: kill %s\n' \
        "$spid" "$(( s_et / 60 ))" "$ROOT" "$spid" >&2
      _notify warn "orphaned pid $spid running $(( s_et / 60 ))m in $ROOT — kill $spid" >/dev/null 2>&1 &
      last="$now"
    fi
    newf+="$spid|$last"$'\n'
  done
  printf '%s' "$newf" > "$wf" 2>/dev/null || true
}

# This function is self-contained: it does its own cmd_pick for the stale path.
_human_backoff_gate() {
  local _hb; _hb="$(_config_get human_backoff)"; _hb="${_hb:-1}"
  # human_backoff=0 → feature disabled; always proceed.
  [[ "$_hb" == "0" ]] && return 1
  # Reset upvars so each call starts fresh.
  _isa_pid=""; _isa_status=""; _isa_status_updated_at=""; _isa_stale_pid=""
  if _interactive_session_active "$ROOT"; then
    local _status_lc _grace _idle_ms _now _ts _age _max_age
    _status_lc="$(printf '%s' "$_isa_status" | tr '[:upper:]' '[:lower:]')"
    _grace="$(_config_get human_idle_grace_mins)"; _grace="${_grace:-5}"
    _valid_positive_int "$_grace" || _grace=5
    if [[ "$_status_lc" == "idle" ]]; then
      _backoff_waiting_reset                     # #55: not 'waiting' -> clear strikes
      if _ts="$(_epoch_ms "$_isa_status_updated_at")"; then
        _now="$(_now_ms)"
        if [[ "$_now" =~ ^[0-9]+$ && "$_now" -ge "$_ts" ]]; then
          _idle_ms=$((_grace * 60 * 1000))
          _age=$((_now - _ts))
          _max_age=$((30 * 24 * 60 * 60 * 1000))
          if [[ "$_age" -le "$_max_age" && "$_age" -ge "$_idle_ms" ]]; then
            return 1
          fi
        fi
      fi
    elif [[ "$_status_lc" == "waiting" ]]; then
      # #55: 3-strike persistence for the undocumented 'waiting' status — proceed only
      # after it holds for waiting_backoff_strikes consecutive heartbeat ticks.
      if [[ -n "$_isa_status_updated_at" ]]; then
        local _strikes _cnt
        _strikes="$(_config_get waiting_backoff_strikes)"; _strikes="${_strikes:-3}"
        _valid_positive_int "$_strikes" || _strikes=3
        _cnt="$(_backoff_waiting_bump "$_isa_pid" "$_isa_status_updated_at")"
        [[ "$_cnt" =~ ^[0-9]+$ ]] || _cnt=1
        if [[ "$_cnt" -ge "$_strikes" ]]; then
          # Do NOT reset here: while 'waiting' persists we keep proceeding every tick
          # (the counter stays >= strikes; the same-run second gate call dedups to the
          # same count). It resets only when the session leaves 'waiting' (status change
          # -> the busy/idle/other branches reset) or the session goes away.
          printf 'deputy: interactive Claude session in %s held '\''waiting'\'' %s consecutive ticks (>= %s strikes) — proceeding.\n' \
            "$ROOT" "$_cnt" "$_strikes" >&2
          return 1
        fi
        printf 'deputy: interactive Claude session in %s (PID: %s) '\''waiting'\'' — strike %s/%s, backing off (next heartbeat will retry).\n' \
          "$ROOT" "$_isa_pid" "$_cnt" "$_strikes" >&2
        return 0
      fi
      _backoff_waiting_reset                     # 'waiting' without a timestamp -> reset
    else
      _backoff_waiting_reset                     # busy/shell/unknown -> reset strikes
    fi
    # Live interactive session: busy, recently idle (within grace), 'waiting' without a
    # reliable timestamp, or an unknown status — back off.
    printf 'deputy: interactive Claude session active in %s (PID: %s, status: %s) — backing off (next heartbeat will retry).\n' \
      "$ROOT" "$_isa_pid" "${_isa_status:-unknown}" >&2
    return 0
  elif [[ -n "$_isa_stale_pid" ]]; then
    _backoff_waiting_reset                       # #55: no live session -> clear strikes
    # Stale session file (dead PID) in this repo, no live session.
    local _stale_item; _stale_item="$(cmd_pick)"
    if [[ -z "$_stale_item" ]]; then
      # Nothing to surface — idle queue; log and proceed.
      printf 'deputy: stale Claude session file found (PID %s, process dead) — no runnable items to surface; proceeding.\n' \
        "$_isa_stale_pid" >&2
    else
      # Cascade guard: do not surface a second item if one is already surfaced.
      # #53: count only BLOCKING surfaces — worker proposals (also 'surfaced') must
      # not suppress surfacing a genuinely-stuck item.
      local _surfaced_count
      _surfaced_count="$(_blocking_surfaced_count)"
      if [[ "${_surfaced_count:-0}" -gt 0 ]]; then
        printf 'deputy: stale Claude session file found (PID %s) — an item is already surfaced; skipping cascade surface.\n' \
          "$_isa_stale_pid" >&2
        return 0
      fi
      # Surface the item. Only write the note if the state transition succeeds.
      local _surf_parsed _surf_prio_rest _surf_prio _surf_id_rest _surf_id _surf_desc _surf_slug _surf_qf _surf_set_rc
      _surf_parsed="$(_parse_item "$_stale_item")"
      _surf_prio_rest="${_surf_parsed#*|}"; _surf_prio="${_surf_prio_rest%%|*}"
      _surf_id_rest="${_surf_prio_rest#*|}"; _surf_id="${_surf_id_rest%%|*}"; _surf_desc="${_surf_id_rest#*|}"
      _surf_slug="$(_wp_slug "$_surf_id" "$_surf_desc")"
      _surf_qf="$STATE_DIR/${_surf_slug}.questions.md"
      _surf_set_rc=0
      cmd_set "$_stale_item" surfaced || _surf_set_rc=$?
      if [[ "$_surf_set_rc" -eq 0 ]]; then
        local _surf_line_surfaced
        _surf_line_surfaced="$(_serialize_item surfaced "$_surf_prio" "$_surf_id" "$_surf_desc")"
        printf 'Stale Claude session file found (PID %s, process dead) with cwd in this repo — a sign of an abnormal Claude Code crash. Deputy surfaced this item instead of running, so you can check. Resolve by removing the stale ~/.claude/sessions/%s.json (or confirming nothing'"'"'s wrong), then revive with: deputy set "%s" waiting.\n' \
          "$_isa_stale_pid" "$_isa_stale_pid" "$_surf_line_surfaced" >> "$_surf_qf"
        printf 'deputy: stale Claude session file (PID %s) — surfaced "%s" for human review.\n' \
          "$_isa_stale_pid" "$_stale_item" >&2
      else
        printf 'deputy: stale Claude session file (PID %s) — could not surface item (set failed); stopping.\n' \
          "$_isa_stale_pid" >&2
      fi
      return 0
    fi
  fi
  # No session detected — proceed.
  _backoff_waiting_reset                         # #55: no session -> clear strikes
  return 1
}

# Spawn the orchestrator for a claimed item. If DEPUTY_ORCHESTRATOR_CMD is set
# #64: run the worker command inside a read-only sandbox so it CANNOT write to the repo's
# CODE — only .deputy/ (queue state + the .deputy/wt worktree) and BACKLOG.md are writable;
# the rest of the filesystem (HOME, network, codex/gemini configs) is normal so the worker
# still functions. cwd is pinned to the worktree, which is the root cause: cron's cwd is the
# repo root, so a worker's relative-path Bash writes (cat>tests/x, sed -i bin/y) escaped into
# the main tree. When bwrap is absent or config sandbox=0, fall back to cwd-pinning only
# (the root-cause fix still applies) with a one-line warning.
_sandbox_worker() {
  local wt sb _cd; wt="$(_wt_path)"; sb="$(_config_get sandbox)"; sb="${sb:-1}"
  # #68: the worktree may not exist yet at COLD-START spawn (the worker creates it via
  # wt-create during its run), and bwrap --chdir / cd to a missing dir aborts the worker
  # before it can start. Pin to the worktree when it exists (full cwd-pin), else fall back
  # to .deputy — rw-bound, always present (STATE_DIR), and CONTAINED (not the repo code
  # tree, which stays --ro-bind), so the #64 breach stays closed either way.
  _cd="$ROOT/.deputy"; [[ -d "$wt" ]] && _cd="$wt"
  if [[ "$sb" != "0" ]] && command -v bwrap >/dev/null 2>&1; then
    # --unshare-pid: new PID namespace so the worker can't see (and escape via
    # /proc/<host-pid>/root/) processes outside the sandbox. Reaping is unaffected — #58
    # kills the host-side process group from outside the sandbox.
    local -a b=( --unshare-pid --bind / / --dev-bind /dev /dev --proc /proc
                 --ro-bind "$ROOT" "$ROOT"
                 --bind "$ROOT/.git" "$ROOT/.git"
                 --bind "$ROOT/.deputy" "$ROOT/.deputy" )
    [[ -e "$ROOT/BACKLOG.md" ]] && b+=( --bind "$ROOT/BACKLOG.md" "$ROOT/BACKLOG.md" )
    b+=( --chdir "$_cd" )
    bwrap "${b[@]}" "$@"
    return $?
  fi
  [[ "$sb" == "0" ]] || printf 'deputy: bwrap unavailable — worker cwd-pinned to the worktree but NOT OS read-only sandboxed (#64).\n' >&2
  ( cd "$_cd" && "$@" )
}

# (tests / custom drivers), call it as `<cmd> <item-line> <provider>`. Otherwise
# build a headless prompt that runs the deputy orchestrator skill on this one item.
_spawn_orchestrator() {
  local item="$1" provider="$2"
  # #60: signal autonomous/headless to the worker (SKILL keys off it; the guardrail enforces
  # surface-not-merge independently). 1 = headless/cron, 0 = headed/interactive.
  local _headless; _run_is_headed && _headless=0 || _headless=1
  if [[ -n "${DEPUTY_ORCHESTRATOR_CMD:-}" ]]; then
    DEPUTY_HEADLESS="$_headless" "$DEPUTY_ORCHESTRATOR_CMD" "$item" "$provider"
    return $?
  fi
  local prompt
  prompt="You are the Deputy orchestrator — use the 'deputy' skill. Work this ONE claimed backlog item end-to-end per the skill's loop, then stop.
Repo root: $ROOT
Item (the exact current BACKLOG.md line — pass it verbatim to 'deputy set'): $item
Provider for coding: $provider
Use the 'deputy' CLI for ALL state changes (deputy set / wt-create / wt-remove / config / protected); never edit BACKLOG.md directly. Honor the protected-path gate and run an xReview (gemini) before each commit. The item MUST end marked done/failed/surfaced/cancelled/duplicate via 'deputy set \"<line>\" <state>'."
  local gset; gset="$(_guardrail_settings_path)"
  DEPUTY_GUARDED=1 DEPUTY_HEADLESS="$_headless" DEPUTY_ACTIVE_RUN_PID="$$" DEPUTY_WT="$(_wt_path)" DEPUTY_ROOT="$ROOT" \
    _sandbox_worker claude -p "$prompt" --model claude-sonnet-4-6 \
      --output-format stream-json --verbose \
      --allowedTools "Bash,Edit,Write,Read,Glob,Grep" \
      --settings "$gset"
}

# Determine the default branch for the repo rooted at $ROOT.
# Echoes the branch name, or empty string if undeterminable.
# Detection order:
#   1. origin/HEAD symbolic-ref (most authoritative)
#   2. local 'main' branch exists
#   3. local 'master' branch exists
#   4. git config init.defaultBranch
_default_branch() {
  local b
  # 1. Try origin/HEAD symbolic-ref (works when a remote is configured)
  b="$(git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')"
  [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
  # 2. Local 'main' branch
  if git -C "$ROOT" show-ref --quiet refs/heads/main 2>/dev/null; then
    printf 'main'; return 0
  fi
  # 3. Local 'master' branch
  if git -C "$ROOT" show-ref --quiet refs/heads/master 2>/dev/null; then
    printf 'master'; return 0
  fi
  # 4. git config init.defaultBranch
  b="$(git -C "$ROOT" config init.defaultBranch 2>/dev/null || true)"
  [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
  # Undeterminable
  printf ''
}

# #51: headed (live-streaming) vs headless (buffered) run output. Headed when the
# run is interactive — stdout is a TTY — UNLESS opted out via the --headless flag
# (_RUN_HEADLESS=1) or `headed=0` in .deputy/config. cron/no-TTY runs are always
# headless. Called only within cmd_run's call chain (dynamic scope supplies
# _RUN_HEADLESS).
_run_is_headed() {
  [[ "${_RUN_HEADLESS:-0}" == "1" ]] && return 1
  [[ "$(_config_get headed)" == "0" ]] && return 1
  [[ -t 1 ]]
}

# Run the orchestrator for one item, logging to $3. Headed -> stream live via tee
# (the human watches in real time) while still capturing the log; headless -> buffer
# to the log, then print it once. $log is ALWAYS written so _detect_outcome/quota
# parsing is mode-independent. Returns the orchestrator's REAL exit code
# (PIPESTATUS[0] under tee, not tee's). Saves/restores errexit for callers under set -e.
# #59: when the heartbeat AUTONOMOUSLY spawns a worker (headless/no-TTY), announce it loudly
# so an unattended pickup is never silent (the gap behind the 24min invisible runaway): a
# prominent ===SPAWN=== line to stderr (-> cron.log) + a notification. No-ops for interactive
# runs (the human is watching) and when notify_on_spawn=0. Backgrounded; never blocks.
_fire_spawn_notify() {
  local line="$1" pid="${2:-$$}" on parsed _rest id desc
  _run_is_headed && return 0
  on="$(_config_get notify_on_spawn)"; [[ "${on:-1}" == "0" ]] && return 0
  parsed="$(_parse_item "$line")"; _rest="${parsed#*|}"; _rest="${_rest#*|}"
  id="${_rest%%|*}"; desc="${_rest#*|}"
  printf 'deputy: ===SPAWN=== pid=%s item=#%s — autonomous worker started: %s\n' "$pid" "${id:-?}" "$desc" >&2
  # Background by default (a slow push/desktop channel must not delay the spawn);
  # DEPUTY_NOTIFY_SYNC=1 runs it inline (tests).
  if [[ "${DEPUTY_NOTIFY_SYNC:-0}" == "1" ]]; then
    _notify spawn "autonomous worker started for #${id:-?}: $desc" >/dev/null 2>&1 || true
  else
    _notify spawn "autonomous worker started for #${id:-?}: $desc" >/dev/null 2>&1 &
  fi
}

# #63: stable, per-item live log so the worker's output is watchable (deputy watch / the
# auto-tail) instead of buffered to an anonymous temp. Returns the log path and truncates it
# (fresh per attempt). Falls back to a mktemp when the item has no file-safe numeric id.
_run_log_path() {
  local line="$1" id
  id="$(_parse_item "$line")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  if [[ "$id" =~ ^[0-9]+$ ]] && : > "$STATE_DIR/run-$id.log" 2>/dev/null; then
    printf '%s' "$STATE_DIR/run-$id.log"
  else
    mktemp
  fi
}
# #63: drop-in for `rm -f "$log"` at run-completion — archive the stable live log to
# .deputy/logs/<id>.log (latest-wins on a same-id retry); just remove a mktemp fallback.
_archive_run_log() {
  local line="$1" log="$2" id
  id="$(_parse_item "$line")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  if [[ "$id" =~ ^[0-9]+$ && "$log" == "$STATE_DIR/run-$id.log" ]]; then
    { mkdir -p "$STATE_DIR/logs" 2>/dev/null && mv -f "$log" "$STATE_DIR/logs/$id.log" 2>/dev/null; } || rm -f "$log" 2>/dev/null
  else
    rm -f "$log" 2>/dev/null
  fi
  return 0
}

# #66: render a worker's stream-json event stream (stdin) to readable text on stdout. Each
# line that parses as a JSON object is rendered (assistant text; a [tool: name] marker for
# tool_use; a "--- <subtype> ---" divider for the final result); any line that is NOT a JSON
# object (plain-text / mock logs, partial lines) is passed through verbatim, so this is safe
# over any log. Falls back to a plain `cat` when jq is unavailable (no hard jq dependency).
# Shared by the headed tee path and `deputy watch`.
_render_stream() {
  command -v jq >/dev/null 2>&1 || { cat; return; }
  jq -Rr --unbuffered '
    (fromjson? // .) as $e
    | if ($e|type) == "object" then
        if $e.type == "assistant" then
          ( $e.message.content[]?
            | if .type == "text" then .text
              elif .type == "tool_use" then "[tool: \(.name)]"
              else empty end )
        elif $e.type == "result" then "--- \($e.subtype // "result") ---"
        else empty end
      else $e end
  ' 2>/dev/null
}

_run_orchestrator_logged() {
  local item="$1" provider="$2" log="$3" rc _had_e=0
  [[ $- == *e* ]] && _had_e=1
  set +e
  if _run_is_headed; then
    # #66: tee writes the RAW stream-json to $log (kept raw for _detect_outcome + archive),
    # then _render_stream makes the live terminal output readable. rc is still the worker's
    # (PIPESTATUS[0], unaffected by the added render stage).
    _spawn_orchestrator "$item" "$provider" 2>&1 | tee "$log" | _render_stream
    rc=${PIPESTATUS[0]}
  else
    # #58: run the headless worker in its OWN process group (set -m) and, when it returns,
    # reap any children it leaked. Under monitor mode a backgrounded job's PGID == its pid
    # ($!), so kill -- -$wpid targets the worker's group — guarded with wpid != deputy's own
    # pgid so we never SIGTERM deputy's group. rc is the worker's real exit (via wait), which
    # preserves #51 quota detection.
    local _had_m=0; [[ $- == *m* ]] && _had_m=1
    local _self_pgid; _self_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    set -m
    _spawn_orchestrator "$item" "$provider" >"$log" 2>&1 &
    local wpid=$!
    wait "$wpid"; rc=$?
    [[ "$wpid" =~ ^[0-9]+$ && "$wpid" != "$_self_pgid" ]] && kill -TERM -- "-$wpid" 2>/dev/null
    [[ "$_had_m" -eq 1 ]] || set +m
    cat "$log"
  fi
  [[ "$_had_e" -eq 1 ]] && set -e
  return "$rc"
}

# One tick: claim the top item and hand it to the orchestrator. --once = no loop.
# If an integer <id> is given (deputy run <id> or deputy run '#<id>'), run that
# specific item bypassing priority, then return (targeted = one item only).
cmd_run() {
  local once=0 target_id="" _RUN_HEADLESS=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      --headless) _RUN_HEADLESS=1; shift ;;
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

  # #57 (Part B): warn (never kill) about leaked long-running orphans under in-repo
  # Claude sessions that could pin a session busy and stall the heartbeat. Best-effort.
  _warn_stale_orphans || true

  # ── Default-branch guard ────────────────────────────────────────────────────
  # Refuse to run if the repo is on a feature branch. This prevents the cron
  # (cd <repo> && deputy run) from running against un-merged code.
  # Bypass: set DEPUTY_ALLOW_ANY_BRANCH=1 (tests / deliberate use).
  if [[ "${DEPUTY_ALLOW_ANY_BRANCH:-0}" != "1" ]]; then
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local _db; _db="$(_default_branch)"
      if [[ -n "$_db" ]]; then
        local _cur; _cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [[ "$_cur" != "$_db" ]]; then
          printf 'deputy run: repo is on %s%s%s, not the default branch %s%s%s — refusing to run (the runner must operate on the default branch; switch to it, or set DEPUTY_ALLOW_ANY_BRANCH=1 to override).\n' \
            "'" "$_cur" "'" "'" "$_db" "'" >&2
          return 1
        fi
      fi
    fi
  fi

  cmd_recover >/dev/null 2>&1 || true
  if _live_claim_exists; then return 0; fi

  # ── Human-session back-off (startup check) ───────────────────────────────────
  # If an interactive Claude Code session is active in this repo, skip this heartbeat
  # tick to avoid mixing deputy commits with the human's uncommitted work.
  # Disable with: deputy config set human_backoff 0
  # Note: DEPUTY_ALLOW_ANY_BRANCH=1 does NOT bypass this check (independent guards).
  local _isa_pid="" _isa_status="" _isa_status_updated_at="" _isa_stale_pid=""
  if _human_backoff_gate; then return 0; fi

  # Always-on model: do NOT remove the cron line while running. The line persists;
  # each tick is state-aware (skip when live, recover orphans, etc.).
  # #60: cap items per run. Default/clamp to >=1 — there is NO unbounded mode (a 0/unset/
  # invalid value clamps to 1) so one cron tick can't drain+merge the whole queue unsupervised.
  local cap; cap="$(_config_get max_items)"; cap="${cap:-1}"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=1; [[ "$cap" -lt 1 ]] && cap=1
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
    _active_run_acquire "$found_line" "targeted" || return 0
    if ! cmd_claim "$found_line" --pid "$$" >/dev/null 2>&1; then
      _active_run_release
      return 1
    fi
    # Read item line from line 1 of claim file (claim file now has 2 lines).
    running_line="$(sed -n '1p' "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$found_line")"
    log="$(_run_log_path "$running_line")"
    rc=0   # #59: NO spawn-notify here — a targeted `deputy run <id>` is a deliberate invocation, not the heartbeat
    _run_orchestrator_logged "$running_line" "$decision" "$log" || rc=$?   # headed=live tee / headless=buffer+cat; '|| rc=$?' keeps the non-zero return from tripping set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; _archive_run_log "$running_line" "$log"
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      # Always-on: do NOT reschedule the shared cron line for quota.
      # The fixed */N heartbeat will retry on the next tick; quota is a per-task skip.
      printf 'deputy: Claude session limit reached — will retry on next heartbeat tick.\n'
      _active_run_release
      return 0
    fi
    _archive_run_log "$running_line" "$log"
    _active_run_release
    return 0
  fi

  # ── Normal priority-driven run loop ──────────────────────────────────────────
  while :; do
    # Re-evaluate the human-session back-off gate on each iteration so that a
    # session started MID-DRAIN is honoured before we claim the next item.
    _isa_pid=""; _isa_status=""; _isa_status_updated_at=""; _isa_stale_pid=""
    if _human_backoff_gate; then break; fi
    item="$(cmd_pick)"; [[ -n "$item" ]] || break
    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      # Provider unavailable: leave item waiting; the next heartbeat tick will retry.
      return 0
    fi
    _active_run_acquire "$item" "run" || break
    if ! cmd_claim "$item" --pid "$$" >/dev/null 2>&1; then
      _active_run_release
      break
    fi
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
      _active_run_release
      processed=$((processed + 1))
      [[ "$once" -eq 1 ]] && break
      [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
      continue
    fi

    log="$(_run_log_path "$running_line")"
    _fire_spawn_notify "$running_line" "$$"   # #59: announce an autonomous (headless) spawn
    rc=0
    _run_orchestrator_logged "$running_line" "$decision" "$log" || rc=$?   # headed=live tee / headless=buffer+cat; '|| rc=$?' keeps the non-zero return from tripping set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      # Pass only the relevant reset/limit line(s) to the rescheduler (bounded;
      # avoids ARG_MAX on a large log). _parse_reset_hour scans for "<N>am/pm".
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; _archive_run_log "$running_line" "$log"
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
      _active_run_release
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
    _archive_run_log "$running_line" "$log"
    _active_run_release
    processed=$((processed + 1))
    [[ "$once" -eq 1 ]] && break
    [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
  done
  return 0
}

# Remove items of a given state from BACKLOG.md. Default state is "waiting"
# (backward-compatible: bare `deputy clean` removes untouched/waiting items only).
# --dry-run previews only. --state <state> selects a different state to clean.
# <id> (integer, or '#N') cleans a single item by its ID regardless of state.
# Only terminal/inert states are cleanable: waiting, done, failed, cancelled, duplicate.
# Active/checkpointed/awaiting states (running, triaging, surfaced, paused) are refused.
cmd_clean() {
  local dry=0 filter_state="waiting" filter_id=""

  # Arg parsing: tolerant of order; support --state X and --state=X and positional <id>.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --state=*)   filter_state="${1#--state=}"; shift ;;
      --state)
        [[ $# -ge 2 ]] || { printf 'deputy: --state requires an argument\n' >&2; return 2; }
        filter_state="$2"; shift 2 ;;
      '#'*) filter_id="${1#'#'}"; shift ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          filter_id="$1"; shift
        else
          printf 'deputy: clean: unexpected argument: %s\n' "$1" >&2; return 2
        fi ;;
    esac
  done

  if [[ -n "$filter_id" ]]; then
    # ID-targeted clean: find and remove exactly one item by its numeric ID.
    local _cid_alloc_rc=0; _with_lock _allocate_ids || _cid_alloc_rc=$?
    [[ "$_cid_alloc_rc" -ne 0 ]] && return "$_cid_alloc_rc"
    local raw parsed state item_id
    local -a doomed=()
    while IFS= read -r raw; do
      parsed="$(_parse_item "$raw")"
      state="${parsed%%|*}"
      item_id="${parsed#*|}"; item_id="${item_id#*|}"; item_id="${item_id%%|*}"
      if [[ "$item_id" == "$filter_id" ]]; then
        case "$state" in
          running|triaging|surfaced|paused)
            printf 'deputy: refusing to clean item #%s (%s) — active/checkpointed/awaiting; recover or resolve it first\n' \
              "$filter_id" "$state" >&2
            return 1 ;;
        esac
        doomed+=("$raw")
        break
      fi
    done < <(_each_item)

    if [[ "${#doomed[@]}" -eq 0 ]]; then
      printf 'deputy: item #%s not found\n' "$filter_id" >&2
      return 1
    fi
    if [[ "$dry" -eq 1 ]]; then
      printf 'deputy: would remove item #%s: %s\n' "$filter_id" "${doomed[0]}"
      return 0
    fi
    _do_clean_id() {
      local tmp line d r prev_blank=0 _werr=0
      tmp="$(_backlog_mktemp)" || return 1
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
        printf '%s\n' "$line" || _werr=1
      done < "$BACKLOG" > "$tmp" || _werr=1
      # Don't commit a truncated tmp from a partial/ENOSPC write (passes -s guard) (#47).
      [[ "$_werr" -ne 0 ]] && { rm -f "$tmp" 2>/dev/null; return 1; }
      # One transaction: regroup sorts + commits the cleaned temp to BACKLOG (for done
      # items it also strips orphaned release delimiters in the same pass).
      if [[ "$state" == "done" ]]; then
        _REGROUP_STRIP_ORPHANED_DELIMS=1 _regroup_backlog "$tmp" || return 1
      else
        _regroup_backlog "$tmp" || return 1
      fi
      # #53: drop the proposal marker for the removed id (filter_id is validated
      # numeric), only AFTER the removal is persisted, so a freed/reusable id can't
      # inherit a stale proposed-<id> marker.
      rm -f "$STATE_DIR/proposed-$filter_id" "$STATE_DIR/ready-merge-$filter_id" 2>/dev/null || true
    }
    local _cid_rc=0; _with_lock _do_clean_id || _cid_rc=$?
    [[ "$_cid_rc" -eq 0 ]] && _commit_queue "clean"
    [[ "$_cid_rc" -eq 0 ]] && printf 'deputy: cleaned item #%s\n' "$filter_id"
    return "$_cid_rc"
  fi

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
    local tmp line d r prev_blank=0 _werr=0
    tmp="$(_backlog_mktemp)" || return 1
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
      printf '%s\n' "$line" || _werr=1
    done < "$BACKLOG" > "$tmp" || _werr=1
    # Don't commit a truncated tmp from a partial/ENOSPC write (passes -s guard) (#47).
    [[ "$_werr" -ne 0 ]] && { rm -f "$tmp" 2>/dev/null; return 1; }
    # One transaction: regroup sorts + commits the cleaned temp to BACKLOG (for done
    # items it also strips orphaned release delimiters in the same pass).
    if [[ "$filter_state" == "done" ]]; then
      _REGROUP_STRIP_ORPHANED_DELIMS=1 _regroup_backlog "$tmp" || return 1
    else
      _regroup_backlog "$tmp" || return 1
    fi
    # #53: drop any proposal marker for a removed item, only AFTER the removal is
    # persisted, so a freed (and later reusable) id can never inherit a stale
    # .deputy/proposed-<id> marker that would hide a genuine surfaced blocker.
    local _dc_parsed _dc_rest _dc_id
    for r in "${doomed[@]}"; do
      _dc_parsed="$(_parse_item "$r")"
      _dc_rest="${_dc_parsed#*|}"; _dc_rest="${_dc_rest#*|}"; _dc_id="${_dc_rest%%|*}"
      [[ "$_dc_id" =~ ^[0-9]+$ ]] && rm -f "$STATE_DIR/proposed-$_dc_id" "$STATE_DIR/ready-merge-$_dc_id" 2>/dev/null || true
    done
  }
  local _clean_rc=0; _with_lock _do_clean || _clean_rc=$?
  [[ "$_clean_rc" -eq 0 ]] && _commit_queue "clean"
  [[ "$_clean_rc" -eq 0 ]] && printf 'deputy: cleaned %d %s item(s)\n' "${#doomed[@]}" "$filter_state"
  return "$_clean_rc"
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

  # 4. Surfaced — pending human response + question files
  printf '%s\n' "-- Surfaced items (awaiting human response) --"
  if [[ "${#surfaced_items[@]}" -eq 0 ]]; then
    printf '  (none)\n'
  else
    for item in "${surfaced_items[@]}"; do
      printf '  ? %s\n' "${item#*|}"
    done
  fi
  shopt -s nullglob
  local qf
  for qf in "$STATE_DIR"/*.questions.md; do
    printf '\n  --- %s ---\n' "$(basename "$qf")"
    sed 's/^/  /' "$qf"
  done
  shopt -u nullglob
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

  printf '%s\n' "-- Status Digest --"
  cmd_status

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

# #63: live-tail the currently-running worker's output (the stable per-item log). The
# watcher brings its own TTY, so this works from ANY terminal — even one that didn't launch
# the run (the watch-the-headless-worker case). Ctrl-C detaches without affecting the run.
cmd_watch() {
  local d="$ACTIVE_RUN_DIR" item pid id log i
  if [[ ! -d "$d" ]] || ! _active_run_live "$d"; then
    printf 'deputy: no worker is running. (Past run logs are archived under %s/logs/.)\n' "$STATE_DIR"
    return 0
  fi
  item="$(sed -n '1p' "$d/item" 2>/dev/null || true)"
  pid="$(sed -n '1p' "$d/pid" 2>/dev/null || true)"
  id="$(_parse_item "$item")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  [[ "$id" =~ ^[0-9]+$ ]] || { printf 'deputy: a worker is running but its item has no id to watch.\n' >&2; return 1; }
  log="$STATE_DIR/run-$id.log"
  # The lock is published just before the log is created — wait briefly for the file.
  for i in $(seq 1 20); do [[ -e "$log" ]] && break; sleep 0.25; done
  [[ -e "$log" ]] || { printf 'deputy: worker #%s is starting; no output yet.\n' "$id" >&2; return 0; }
  printf 'deputy: watching #%s (pid %s) — Ctrl-C to detach (the run keeps going)...\n' "$id" "$pid" >&2
  # --pid: exit when the run process ends; -f follows the open fd cleanly across the archive mv.
  # #66: render the stream-json log to readable text. Capture tail's exit (PIPESTATUS[0])
  # under set +e: only a CLEAN exit (the run actually ended, tail rc 0) prints the archived
  # line — a Ctrl-C detach (tail killed, non-zero) must NOT falsely claim the run ended.
  local _had_e=0; [[ $- == *e* ]] && _had_e=1; set +e
  tail --pid="$pid" -f "$log" | _render_stream
  local trc=${PIPESTATUS[0]}
  [[ "$_had_e" -eq 1 ]] && set -e
  [[ "$trc" -eq 0 ]] && printf 'deputy: run #%s ended — output archived to %s/logs/%s.log\n' "$id" "$STATE_DIR" "$id" >&2
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    version|--version|-V) cmd_version; return $? ;;
    _parse) _parse_item "${2:-}"; printf '\n'; return 0 ;;
    list) shift; cmd_list "$@"; return $? ;;
    _serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}" "${5:-}" && printf '\n' || return 1 ;;
    add) shift; cmd_add "$@" ;;
    status) cmd_status; return 0 ;;
    watch|tail) cmd_watch; return $? ;;
    pick) cmd_pick; return 0 ;;
    set) shift; cmd_set "$@"; return $? ;;
    claim) shift; cmd_claim "$@"; return $? ;;
    recover) cmd_recover; return 0 ;;
    review) cmd_review; return 0 ;;
    clean) shift; cmd_clean "$@"; return $? ;;
    reflect) shift; cmd_reflect "$@"; return $? ;;
    release) shift; cmd_release "$@"; return $? ;;
    release-notes) cmd_release_notes; return $? ;;
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
    route) shift; _route "${1:-}" "${2:-}" "${3:-}"; return $? ;;
    avail) _availability; return 0 ;;
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
    review-log) shift; cmd_review_log "$@"; return $? ;;
    _wp_show) shift; cmd_wp_show "$@"; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
