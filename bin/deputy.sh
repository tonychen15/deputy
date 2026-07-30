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
# #76: self-heal — auto-seed missing per-project default files from the release templates
# so a customer never has to re-run `init` after a deputy upgrade merely to materialize
# defaults. Idempotent (only when absent) and best-effort (read-only repo / sandbox safe).
# This is purely for visibility/editability: missing config keys already fall back to
# call-site defaults, and protected globs are layered from the template at read time
# (_protected_violation), so behaviour is unchanged whether or not these files exist.
for _seed in config protected; do
  if [[ ! -e "$STATE_DIR/$_seed" && -f "$SRC_DIR/templates/$_seed" ]]; then
    cp "$SRC_DIR/templates/$_seed" "$STATE_DIR/$_seed" 2>/dev/null || true
  fi
done
unset _seed
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
# Tags are recognized ONLY in the tag zone (immediately after the status prefix), never
# inside the description body. The parser is CONTENT-driven, not position-driven: a tag is
# a PRIORITY if it starts with 'P' ([P0]..[P4]), or an ID if it is '[#N]'. So either order
# ([#N][Pn] or [Pn][#N]) parses the same — old files keep working and re-serialize to the
# canonical [#N][Pn] (#62).
_parse_item() {
  local line="$1" state="waiting" prio="" id="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?+!%=^&\;#>])[[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;;  '@') state=running ;;    '?') state=surfaced ;;
      '+') state=done ;;      '!') state=failed ;;
      '%') state=cancelled ;; '=') state=duplicate ;; '^') state=paused ;;
      ';') state=deferred ;;
      # #112: work is finished and the branch is waiting only on a mechanical merge. NOT
      # runnable (no worker is ever spawned on it) and NOT an attention state (it never
      # enters the human's pickup queue) — the runner drains it on a later tick.
      '&') state=pending-merge ;;
      # Back-compat read of the pre-migration prefixes ('#' done, '>' deferred);
      # _serialize_item always writes the new symbols, so any old line migrates to
      # '+'/';' the next time it is re-serialized (e.g. on _regroup_backlog).
      '#') state=done ;;      '>') state=deferred ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  # Tag zone: consume a priority tag ([Pn]), an id tag ([#N]), and a prereq tag
  # ([prereq:#N,#M,...]) in any order (all optional, at most one each).
  # The prereq tag is stripped from the tag zone so desc stays clean — callers
  # that need it use _prereq_ids_from_line on the raw line directly.
  local consumed=1
  while [[ "$consumed" -eq 1 ]]; do
    consumed=0
    if [[ -z "$prio" && "$line" =~ ^\[(P[0-4])\][[:space:]]*(.*) ]]; then
      prio="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; consumed=1
    fi
    # id tag: requires the '#' marker — a bare [N] is NOT an id, so a hand-edited
    # '[2024] roadmap'-style description is never misread as an id. An id is a positive
    # integer with an OPTIONAL single '.<sub>' grouping suffix ([#7] or [#145.2]); '#145'
    # and '#145.2' are INDEPENDENT tasks (no coupling) — the '.2' is a human-only label
    # saying they belong to the same effort. BASH_REMATCH[2] is the optional '.<sub>'
    # group, so the description remainder is [3].
    if [[ -z "$id" && "$line" =~ ^\[#([0-9]+(\.[0-9]+)?)\][[:space:]]*(.*) ]]; then
      id="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[3]}"; consumed=1
    fi
    # #114: prereq tag — strip from tag zone so desc stays clean and _desc_exists dedup
    # works. Callers needing prereq IDs use _prereq_ids_from_line on the RAW line.
    # Strict grammar: [prereq:#N(.M)?(,#N(.M)?)*] — BASH_REMATCH[5] is the remainder.
    if [[ "$line" =~ ^\[prereq:(#[0-9]+([.][0-9]+)?(,#[0-9]+([.][0-9]+)?)*)\][[:space:]]*(.*) ]]; then
      line="${BASH_REMATCH[5]}"; consumed=1
    fi
  done
  desc="$line"
  printf '%s|%s|%s|%s' "$state" "$prio" "$id" "$desc"
}

# #114: extract comma-separated prereq IDs (without '#') from the TAG ZONE of a raw line.
# Returns e.g. "3,7" from "[#5][P1][prereq:#3,#7] desc". Returns empty if no prereq tag.
# Callers must pass the RAW line (before _parse_item), since _parse_item strips the tag.
# Scans only the tag zone (after optional state prefix and [#N]/[Pn] tags) to avoid
# false-positives from descriptions containing "[prereq:...]" text literally.
_prereq_ids_from_line() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  # Strip optional state prefix — use if/then to avoid Bash operator-parsing quirks
  # with & and > inside [[ ... ]] && ... (same char class as _parse_item line 158).
  if [[ "$line" =~ ^([~@?+!%=^&\;#>])[[:space:]]*(.*) ]]; then line="${BASH_REMATCH[2]}"; fi
  # Scan through [#N] and [Pn] tags in the tag zone, looking for [prereq:...]
  local consumed=1
  while [[ "$consumed" -eq 1 ]]; do
    consumed=0
    [[ "$line" =~ ^\[P[0-4]\][[:space:]]*(.*) ]] && { line="${BASH_REMATCH[1]}"; consumed=1; }
    [[ "$line" =~ ^\[#[0-9]+(\.[0-9]+)?\][[:space:]]*(.*) ]] && { line="${BASH_REMATCH[2]}"; consumed=1; }
    # Strict prereq grammar: [prereq:#N(.M)?(,#N(.M)?)*] — no trailing commas, no spaces.
    if [[ "$line" =~ ^\[prereq:(#[0-9]+(\.[0-9]+)?(,#[0-9]+(\.[0-9]+)?)*)\] ]]; then
      printf '%s' "${BASH_REMATCH[1]//#/}"   # strip all '#' → "3,7"
      return 0
    fi
  done
}

# #114: get the state of an item by its numeric ID. Prints the state string or "missing"
# if the ID is not found in BACKLOG. O(N) — only called from _prereqs_satisfied.
_item_state_by_id() {
  local want_id="$1" raw parsed rid
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    rid="${parsed#*|}"; rid="${rid#*|}"; rid="${rid%%|*}"
    if [[ "$rid" == "$want_id" ]]; then
      printf '%s' "${parsed%%|*}"; return 0
    fi
  done < <(_each_item)
  printf 'missing'
}

# #114: return 0 (satisfied) or 1 (blocked) for the item whose raw line is $1.
# Satisfied means all prereq IDs are in state done/cancelled/duplicate.
# "missing" prereq IDs (dangling) are treated as NOT satisfied (unsatisfiable).
_prereqs_satisfied_for_line() {
  local raw="$1"
  local prereq; prereq="$(_prereq_ids_from_line "$raw")"
  [[ -z "$prereq" ]] && return 0   # no prereqs → always satisfied
  local prid pstate
  local IFS=','
  for prid in $prereq; do
    pstate="$(_item_state_by_id "$prid")"
    case "$pstate" in
      done|cancelled|duplicate) ;;  # satisfied
      *) return 1 ;;                # unsatisfied (waiting/running/failed/missing/etc.)
    esac
  done
  return 0
}

# Build a canonical line from (state, priority, id, description[, prereq]).
# Canonical order (#62): <status>[#N][Pn][prereq:#M,...] description — id first, then
# priority, then optional prereq tag (#114). The status symbol directly abuts what follows
# (no space): `@[#3][P0] x`, `[#7] x`, `Plain`.
# Reads are order-agnostic (see _parse_item), so old `[Pn][#N]` lines migrate on the
# next re-serialize. Prereq ($5) is a comma-separated list of IDs WITHOUT '#' (e.g. "3,7");
# callers that do a parse→serialize round-trip must extract it via _prereq_ids_from_line
# and pass it here so the tag is preserved. Omit or pass "" to emit no prereq tag.
_serialize_item() {
  local state="$1" prio="$2" id="$3" desc="$4" prereq="${5:-}" prefix="" body=""
  case "$state" in
    waiting)   prefix="" ;;  triaging)  prefix="~" ;; running)   prefix="@" ;;
    surfaced)  prefix="?" ;; done)      prefix="+" ;; failed)    prefix="!" ;;
    cancelled) prefix="%" ;; duplicate) prefix="=" ;; paused)    prefix="^" ;;
    deferred)  prefix=";" ;;  pending-merge) prefix="&" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  body=""
  [[ -n "$id"   ]] && body="${body}[#${id}]"
  [[ -n "$prio" ]] && body="${body}[${prio}]"
  # #114: re-attach prereq tag after [Pn]; format "3,7" → "[prereq:#3,#7]"
  if [[ -n "$prereq" ]]; then
    body="${body}[prereq:#${prereq//,/,#}]"
  fi
  if [[ -n "$body" ]]; then
    [[ -n "$desc" ]] && body="${body} ${desc}"
  else
    body="$desc"
  fi
  printf '%s%s' "$prefix" "$body"
}

# Canonical identity of an item line: parse then re-serialize, so two lines for the SAME
# item match regardless of tag order ([Pn][#N] vs [#N][Pn], #62), id '#'-form, or legacy
# status symbols. Used by cmd_recover to match a claim's stored line against the current
# (possibly migrated) BACKLOG line — a raw string compare would miss a migrated line.
_canon_line() {
  local p s pr i d
  p="$(_parse_item "$1")"
  s="${p%%|*}"; p="${p#*|}"; pr="${p%%|*}"; p="${p#*|}"; i="${p%%|*}"; d="${p#*|}"
  _serialize_item "$s" "$pr" "$i" "$d"
}

# #70: per-item runtime trails live in type subfolders to keep .deputy/ tidy:
#   reviews/<slug>.md  questions/<slug>.md  fails/<slug>.md
# Returns the path for <type> (reviews|questions|fails) + <slug>, creating the subfolder.
_trail_path() {
  mkdir -p "$STATE_DIR/$1" 2>/dev/null || true
  printf '%s/%s/%s.md' "$STATE_DIR" "$1" "$2"
}

# Move a flat trail into its subfolder. On collision (a stale flat write — e.g. from a
# SKILL that still writes flat — over an already-migrated subfolder trail), keep the NEWER
# content and drop the other, so there's never a duplicate left behind (which would make
# reflect show it twice) nor a lingering flat file.
_move_trail() {
  local src="$1" dest="$2"
  if [[ -e "$dest" ]]; then
    if [[ "$src" -nt "$dest" ]]; then mv -f "$src" "$dest" 2>/dev/null || rm -f "$src" 2>/dev/null || true
    else rm -f "$src" 2>/dev/null || true; fi
  else
    mv "$src" "$dest" 2>/dev/null || true
  fi
}

# #70: one-shot migration — move pre-existing FLAT trails (.deputy/<slug>.{review,questions,
# fail}.md) into their subfolders. Idempotent + cheap: only acts when a flat trail exists
# (after migration the globs are empty).
_migrate_trails() {
  [[ -d "$STATE_DIR" ]] || return 0
  shopt -s nullglob
  local f base found=""
  for f in "$STATE_DIR"/*.review.md "$STATE_DIR"/*.questions.md "$STATE_DIR"/*.fail.md; do found=1; break; done
  if [[ -n "$found" ]]; then
    mkdir -p "$STATE_DIR/reviews" "$STATE_DIR/questions" "$STATE_DIR/fails" 2>/dev/null || true
    for f in "$STATE_DIR"/*.review.md;    do base="${f##*/}"; _move_trail "$f" "$STATE_DIR/reviews/${base%.review.md}.md"; done
    for f in "$STATE_DIR"/*.questions.md; do base="${f##*/}"; _move_trail "$f" "$STATE_DIR/questions/${base%.questions.md}.md"; done
    for f in "$STATE_DIR"/*.fail.md;      do base="${f##*/}"; _move_trail "$f" "$STATE_DIR/fails/${base%.fail.md}.md"; done
  fi
  shopt -u nullglob
}

cmd_list() {
  # State filter — three equivalent forms (canonical first): a bare '<state>'
  # ('deputy list waiting'), '--state <state>', or the shorthand '--<state>'
  # ('deputy list --waiting'). Bare 'deputy list' lists all.
  # ID filter — three equivalent forms: '#<N>' (quoted), bare positive integer <N>,
  # or '--id <N>'/'--id=<N>'. State and ID filters can coexist (ANDed).
  # --porcelain emits stable machine-readable 'state|prio|id|desc' per line (desc is the raw
  # remainder after the 3rd pipe and may contain '|'; prio/id empty when unset); composes with
  # all filters and suppresses the human blank-line separator and 0-tasks message.
  local filter="" id_filter="" porcelain=0 arg s
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --porcelain)
        porcelain=1; shift ;;
      --state=*)
        s="${arg#--state=}"
        if _valid_state "$s"; then filter="$s"; shift
        else printf 'deputy: list: unknown state: %s\n' "$s" >&2; return 2; fi ;;
      --state)
        [[ $# -ge 2 ]] || { printf 'deputy: list: --state requires a <state>\n' >&2; return 2; }
        if _valid_state "$2"; then filter="$2"; shift 2
        else printf 'deputy: list: unknown state: %s\n' "$2" >&2; return 2; fi ;;
      --id=*)
        s="${arg#--id=}"
        if _valid_item_id "$s"; then
          [[ -n "$id_filter" ]] && { printf 'deputy: list: duplicate id filter\n' >&2; return 2; }
          id_filter="$s"; shift
        else printf 'deputy: list: --id requires an item id (e.g. 7 or 145.2), got: %s\n' "$s" >&2; return 2; fi ;;
      --id)
        [[ $# -ge 2 ]] || { printf 'deputy: list: --id requires a <N>\n' >&2; return 2; }
        s="$2"
        if _valid_item_id "$s"; then
          [[ -n "$id_filter" ]] && { printf 'deputy: list: duplicate id filter\n' >&2; return 2; }
          id_filter="$s"; shift 2
        else printf 'deputy: list: --id requires an item id (e.g. 7 or 145.2), got: %s\n' "$s" >&2; return 2; fi ;;
      --*)
        s="${arg#--}"
        if _valid_state "$s"; then filter="$s"; shift
        else printf 'deputy: list: unknown flag: %s\n' "$arg" >&2; return 2; fi ;;
      '#'[0-9]*)
        # quoted '#<N>' form: e.g. deputy list '#42'
        s="${arg#'#'}"
        if _valid_item_id "$s"; then
          [[ -n "$id_filter" ]] && { printf 'deputy: list: duplicate id filter\n' >&2; return 2; }
          id_filter="$s"; shift
        else printf 'deputy: list: invalid id: %s\n' "$arg" >&2; return 2; fi ;;
      '#'*)
        printf 'deputy: list: invalid id: %s\n' "$arg" >&2; return 2 ;;
      [0-9]*)
        # bare positive integer form: e.g. deputy list 42
        if _valid_item_id "$arg"; then
          [[ -n "$id_filter" ]] && { printf 'deputy: list: duplicate id filter\n' >&2; return 2; }
          id_filter="$arg"; shift
        else printf 'deputy: list: invalid id: %s (want an item id, e.g. 7 or 145.2)\n' "$arg" >&2; return 2; fi ;;
      *)
        if _valid_state "$arg"; then filter="$arg"; shift
        else printf 'deputy: list: unexpected argument: %s (want a <state>, --<state>, or <id>)\n' "$arg" >&2; return 2; fi ;;
    esac
  done
  _with_lock _allocate_ids
  local raw parsed count=0 _ls _lp _li _ld _lrest _ll_prereq
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    _ls="${parsed%%|*}"; _lrest="${parsed#*|}"
    _lp="${_lrest%%|*}"; _lrest="${_lrest#*|}"
    _li="${_lrest%%|*}"; _ld="${_lrest#*|}"
    [[ -n "$filter"    && "$_ls" != "$filter"    ]] && continue
    [[ -n "$id_filter" && "$_li" != "$id_filter" ]] && continue
    # #92: blank line between items when a state filter is active (after the filters, so
    # skipped items never produce a phantom separator; count>0 means we already printed one).
    # Suppressed under --porcelain (#93) so machine output stays cleanly delimiter-parseable.
    [[ -n "$filter" && "$count" -gt 0 && "$porcelain" -eq 0 ]] && printf '\n'
    _ll_prereq="$(_prereq_ids_from_line "$raw")"
    if [[ "$porcelain" -eq 1 ]]; then
      printf '%s|%s|%s|%s\n' "$_ls" "$_lp" "$_li" "$_ld"
    else
      # #114: pass prereq so the [prereq:...] tag round-trips in the output line.
      printf '%s\n' "$(_serialize_item "$_ls" "$_lp" "$_li" "$_ld" "$_ll_prereq")"
      # For attention states (surfaced/failed/deferred/paused/cancelled), print the indented
      # detail block (status/details/summary/action) beneath the item; no-op otherwise, and
      # skipped under --porcelain so machine output stays clean.
      _item_detail_block "$_ls" "$_li"
    fi
    count=$(( count + 1 ))
  done < <(_each_item)
  # Task-count summary is human-only — suppressed under --porcelain (#93).
  if [[ "$porcelain" -eq 0 ]]; then
    if [[ "$count" -eq 0 ]]; then
      if [[ -n "$id_filter" && -n "$filter" ]]; then
        printf '0 tasks with id #%s in %s state\n' "$id_filter" "$filter"
      elif [[ -n "$id_filter" ]]; then
        printf '0 tasks with id #%s\n' "$id_filter"
      elif [[ -n "$filter" ]]; then
        printf '0 tasks in %s state\n' "$filter"
      fi
    elif [[ -n "$filter" ]]; then
      local _word; _word="$( [[ "$count" -eq 1 ]] && printf 'task' || printf 'tasks' )"
      printf '\n'
      if [[ -n "$id_filter" ]]; then
        printf '%d %s with id #%s in %s state\n' "$count" "$_word" "$id_filter" "$filter"
      else
        printf '%d %s in %s state\n' "$count" "$_word" "$filter"
      fi
    fi
  fi
  return 0
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
# A backlog item id: a positive integer, optionally with a single '.<sub>' grouping suffix
# (e.g. '7' or '145.2'). Sub-ids are a hand-written organizational label ONLY — '#145' and
# '#145.2' are independent tasks with no scheduling/merge/lifecycle coupling; the '.2' just
# tells a human they belong to the same effort. The '.' is filesystem-safe (markers, logs,
# meta, waypoints) and a valid git-ref char; where an id is spliced into a regex it MUST be
# escaped via _id_re (a bare '.' would match any char). Both the parent and (when present) the
# sub must be POSITIVE and unpadded — '[1-9][0-9]*' rejects '0', '145.0', '0.1' and, as a bonus,
# sidesteps bash's octal-arithmetic trap on a zero-padded token. The parser stays lenient
# ('[0-9]+') so a legacy/hand-typed odd id still parses; validation is where we draw the line.
_valid_item_id() { [[ "${1:-}" =~ ^[1-9][0-9]*(\.[1-9][0-9]*)?$ ]]; }
# Integer sort-key of an item id (the part before an optional '.<sub>'): the value the
# next-id max-scan compares/increments. '7'->7, '145.2'->145, a non-id -> empty (skipped).
_id_int_key() { [[ "${1:-}" =~ ^([0-9]+)(\.[0-9]+)?$ ]] && printf '%s' "${BASH_REMATCH[1]}"; }
# Escape a validated item id for safe interpolation into a grep -E / bash ERE ('.' -> '\.').
_id_re() { printf '%s' "${1//./\\.}"; }

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
  local d="${1:-$ACTIVE_RUN_DIR}" pid recorded_start actual_start owner last_hb hb ttl_sec now
  [[ -d "$d" ]] || return 1
  pid="$(sed -n '1p' "$d/pid" 2>/dev/null || true)"
  owner="$(sed -n '1p' "$d/owner" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # #67: agent-shaped liveness. An agent's active run may have a dead PID between
  # conversational turns, but stays LIVE while its heartbeat is fresh (< 2x
  # heartbeat_mins). A missing/stale heartbeat falls through to PID liveness so the
  # claim still auto-EXPIRES and never stall-locks the queue.
  if [[ "$owner" == "agent" ]]; then
    last_hb="$(sed -n '1p' "$d/heartbeat" 2>/dev/null || true)"
    if [[ "$last_hb" =~ ^[0-9]+$ ]]; then
      hb="$(_config_get heartbeat_mins)"; hb="${hb:-10}"; _valid_positive_int "$hb" || hb=10
      ttl_sec=$(( hb * 60 * 2 )); now="$(date +%s)"
      [[ "$last_hb" -le "$now" && $(( now - last_hb )) -lt "$ttl_sec" ]] && return 0  # reject future ts
    fi
    return 1   # agent liveness is heartbeat-only; stale/missing → EXPIRED (no PID fallthrough)
  fi
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

# Acquire the active-run lock. Split out (vs a nested fn) so a caller already
# holding _with_lock (e.g. cmd_claim's _do_claim) can acquire without re-locking.
# acq_pid is the OWNING process: the long-lived worker ($$) for run/targeted, or
# the orchestrator/agent ($PPID, passed by cmd_claim --agent) so the agent's
# heartbeat refresh — keyed on $PPID — matches the stored pid. Caller holds the lock.
_do_active_run_acquire() {
  local item="${1:-}" owner="${2:-run}" acq_pid="${3:-$$}"
  if [[ -e "$ACTIVE_RUN_DIR" ]]; then
    if _active_run_live "$ACTIVE_RUN_DIR"; then
      printf 'deputy: active run exists (%s) — skipping this tick.\n' "$(_active_run_summary "$ACTIVE_RUN_DIR")" >&2
      return 3
    fi
    rm -rf "$ACTIVE_RUN_DIR"
  fi
  mkdir "$ACTIVE_RUN_DIR" || return 1
  printf '%s\n' "$acq_pid" > "$ACTIVE_RUN_DIR/pid"
  printf '%s\n' "$(_pid_start_time "$acq_pid")" > "$ACTIVE_RUN_DIR/start_time"
  printf '%s\n' "$owner" > "$ACTIVE_RUN_DIR/owner"
  printf '%s\n' "$item" > "$ACTIVE_RUN_DIR/item"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$ACTIVE_RUN_DIR/started_at"
  date +%s > "$ACTIVE_RUN_DIR/heartbeat"
}

# #67: THIS is the flock-atomic "read guard + claim" gate. _with_lock is `flock -x`, so
# _do_active_run_acquire checks the guard (_active_run_live) AND mkdir's the lock in one
# critical section — two cron ticks (or cron vs the agent, which acquires this same lock
# via `claim --agent`) can never both succeed; the loser sees it live and backs off. The
# active-run claim is the PRIMARY cross-party (human/agent/cron) guard; .deputy/wt + the
# session scan are backstops.
_active_run_acquire() {
  _with_lock _do_active_run_acquire "$@"
}

_active_run_release() {
  _do_active_run_release() {
    [[ -d "$ACTIVE_RUN_DIR" ]] || return 0
    local pid owner recorded_start actual_start
    pid="$(sed -n '1p' "$ACTIVE_RUN_DIR/pid" 2>/dev/null || true)"
    owner="$(sed -n '1p' "$ACTIVE_RUN_DIR/owner" 2>/dev/null || true)"
    # #67: an agent run is owned by the orchestrator ($PPID); the deputy CLI ($$) is
    # its child. Match on $PPID (with start-time validation) so we release only our own.
    local self="$$"
    [[ "$owner" == "agent" ]] && self="$PPID"
    [[ "$pid" == "$self" ]] || return 0
    recorded_start="$(sed -n '1p' "$ACTIVE_RUN_DIR/start_time" 2>/dev/null || true)"
    if [[ -n "$recorded_start" ]]; then
      actual_start="$(_pid_start_time "$self")"
      [[ "$actual_start" == "$recorded_start" ]] || return 0
    fi
    rm -rf "$ACTIVE_RUN_DIR"
  }
  _with_lock _do_active_run_release
}

# #67: refresh the heartbeat of THIS orchestrator's agent active-run + claim so the
# agent claim stays live while it actively drives spine verbs. No-op unless an
# agent-owned run/claim exists for our $PPID. Called by the spine verbs.
_active_run_refresh() {
  local now; now="$(date +%s)"
  # active-run heartbeat — write a temp then atomically rename so a concurrent reader
  # never sees a truncated/empty heartbeat (and momentarily mis-expire live work).
  if [[ -d "$ACTIVE_RUN_DIR" \
        && "$(sed -n '1p' "$ACTIVE_RUN_DIR/owner" 2>/dev/null || true)" == "agent" \
        && "$(sed -n '1p' "$ACTIVE_RUN_DIR/pid" 2>/dev/null || true)" == "$PPID" ]]; then
    if printf '%s\n' "$now" > "$ACTIVE_RUN_DIR/.hb.$$" 2>/dev/null; then
      mv -f "$ACTIVE_RUN_DIR/.hb.$$" "$ACTIVE_RUN_DIR/heartbeat" 2>/dev/null || rm -f "$ACTIVE_RUN_DIR/.hb.$$" 2>/dev/null || true
    fi
  fi
  # claim-file heartbeat (line 4), preserving lines 1-3 — temp + atomic rename so a
  # concurrent recover never observes a partial claim and wrongly expires live work.
  local f="$STATE_DIR/$PPID.claim" l1 l2 l3
  if [[ -e "$f" && "$(sed -n '3p' "$f" 2>/dev/null || true)" == "agent" ]]; then
    l1="$(sed -n '1p' "$f" 2>/dev/null || true)"
    l2="$(sed -n '2p' "$f" 2>/dev/null || true)"
    l3="$(sed -n '3p' "$f" 2>/dev/null || true)"
    if [[ -n "$l1" ]] && printf '%s\n%s\n%s\n%s\n' "$l1" "$l2" "$l3" "$now" > "$f.tmp.$$" 2>/dev/null; then
      mv -f "$f.tmp.$$" "$f" 2>/dev/null || rm -f "$f.tmp.$$" 2>/dev/null || true
    fi
  fi
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
# Atomic rename (mv) is preferred — torn-free for lock-less readers — BUT it swaps the
# file's INODE. A sandboxed headless worker bind-mounts BACKLOG.md by inode (#64), so an
# mv by an UNSANDBOXED writer (human/agent on the main tree) while that worker runs would
# orphan the worker's handle mid-run and wedge it (#85). So: use mv only when NO run is
# live (no bind to protect); whenever a run is live — or the dir is read-only (the sandbox
# itself) — write IN-PLACE, which preserves the inode. In-place is safe under _with_lock
# (flock); a .bak copy is taken first so a crash can be diagnosed.
_backlog_commit() {
  local tmp="$1"
  # Guard: tmp must be a non-empty (-s) regular file — prevents replacing
  # BACKLOG.md with truncated/empty output on I/O failure.
  [[ -n "$tmp" && -s "$tmp" && -f "$tmp" ]] || { rm -f "$tmp" 2>/dev/null; return 1; }
  local d; d="$(dirname "$BACKLOG")"
  if [[ -w "$d" ]] && ! _active_run_live; then
    # Dir writable AND no live run to protect: atomic rename (same filesystem, torn-free).
    mv "$tmp" "$BACKLOG" 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
  # A run is live (preserve the worker's inode-pinned bind) OR the dir is read-only
  # (bind-mount sandbox): write in-place when BACKLOG.md itself is writable — this keeps
  # the inode stable. Fail for any other cause (dir ro AND file not writable, ENOSPC, …).
  if [[ -w "$BACKLOG" ]]; then
    local bak="${tmp}.bak"
    cp "$BACKLOG" "$bak" || { rm -f "$tmp"; return 1; }  # backup must succeed
    if cat "$tmp" > "$BACKLOG"; then
      rm -f "$tmp" "$bak" 2>/dev/null || true
      return 0
    fi
    # #86: the in-place write FAILED even though BACKLOG.md looked writable by mode —
    # the hallmark of a stale sandbox bind (dead inode, #82) or a hard I/O error. This is
    # PERSISTENT and retry-proof, so signal it distinctly (exit 3) below (after restore).
    [[ -s "$bak" ]] && cat "$bak" > "$BACKLOG" 2>/dev/null || true
    rm -f "$tmp" "$bak" 2>/dev/null || true
    _backlog_unwritable_signal; return 3
  fi
  # dir NOT writable AND BACKLOG.md NOT writable by mode (e.g. genuinely read-only file):
  # also a persistent, retry-proof failure — same distinct signal.
  rm -f "$tmp" 2>/dev/null || true
  _backlog_unwritable_signal; return 3
}

# #94: On startup/recover, detect a leftover _backlog_commit .bak alongside a torn
# BACKLOG (empty or missing the '## Items' header) and restore from it. A SIGKILL mid
# in-place write is the primary cause; #87's SIGTERM+grace makes the window rare.
# Stale .bak files from prior clean runs are cleaned unconditionally. Caller holds
# _with_lock. Restore is routed through _backlog_commit (mv-or-inplace, atomic).
# Called from _do_recover, which is invoked both at startup (via cmd_recover in cmd_run)
# and on the explicit 'deputy recover' command — covers both cases.
_recover_torn_backlog() {
  local d; d="$(dirname "$BACKLOG")"

  # Deduplicate scan dirs: only add STATE_DIR when it differs from BACKLOG's dir.
  local -a dirs=("$d")
  [[ "$STATE_DIR" != "$d" ]] && dirs+=("$STATE_DIR")

  # Collect all .bak candidates from both _backlog_mktemp drop locations.
  local -a baks=()
  local b dir
  for dir in "${dirs[@]}"; do
    for b in "$dir"/.backlog.tmp.*.bak; do [[ -f "$b" ]] && baks+=("$b"); done
  done
  [[ "${#baks[@]}" -eq 0 ]] && return 0

  # Torn check (strict pre-condition): empty OR missing the '## Items' structure header.
  local torn=0
  if [[ ! -s "$BACKLOG" ]] || ! grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null; then
    torn=1
  fi

  local best=""
  if [[ "$torn" -eq 1 ]]; then
    # Pick the most-recent structurally-valid .bak (mtime + filename for tie-breaking).
    local best_key="" key
    for b in "${baks[@]}"; do
      [[ -s "$b" ]] && grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$b" 2>/dev/null || continue
      key="$(stat -c '%Y %n' "$b" 2>/dev/null)" || continue
      [[ -z "$best" || "$key" > "$best_key" ]] && { best_key="$key"; best="$b"; }
    done

    if [[ -n "$best" ]]; then
      # Restore via _backlog_commit: handles mv-vs-inplace, atomic, inode-safe.
      # _backlog_commit's in-place path creates its own internal .bak (of the torn
      # BACKLOG) and always removes it on both success and failure paths; the final
      # re-glob below catches any edge-case leaks so cleanup is self-contained.
      local restore_tmp
      restore_tmp="$(_backlog_mktemp)" || {
        printf 'deputy: WARNING — torn BACKLOG: cannot create restore tmp (%s preserved)\n' "$best" >&2
        return 0
      }
      if cat "$best" > "$restore_tmp" && _backlog_commit "$restore_tmp"; then
        printf 'deputy: torn BACKLOG restored from .bak (%s)\n' "$best" >&2
        rm -f "$best" "${best%.bak}" 2>/dev/null || true
      else
        rm -f "$restore_tmp" 2>/dev/null || true
        printf 'deputy: WARNING — torn BACKLOG: restore failed (%s preserved)\n' "$best" >&2
      fi
    else
      printf 'deputy: WARNING — BACKLOG appears torn but no structurally-valid .bak found\n' >&2
    fi
  fi

  # Final cleanup pass — re-glob to catch any .bak created by _backlog_commit's
  # in-place path during the restore above (backup of the torn BACKLOG, normally
  # removed by _backlog_commit itself; re-glob is defense-in-depth). We hold
  # _with_lock so no concurrent write can create legitimate .bak files at this point.
  for dir in "${dirs[@]}"; do
    for b in "$dir"/.backlog.tmp.*.bak; do
      [[ -f "$b" ]] || continue
      [[ "$b" == "$best" ]] && continue  # preserved: failed restore candidate
      rm -f "$b" "${b%.bak}" 2>/dev/null || true
    done
  done
}

# #86: one loud, actionable message for an UNRECOVERABLE BACKLOG.md write (stale sandbox
# bind / read-only file / I/O error). A headless worker must NOT death-loop retrying or
# debugging this — after a bounded tryout it should write .deputy/<slug>.fail.md (in
# .deputy/, a dir bind that stays writable) and EXIT; the runner recovers the item.
_backlog_unwritable_signal() {
  printf 'deputy: BACKLOG.md is UNWRITABLE (persistent, not retryable — likely a stale sandbox bind or read-only file). Do NOT retry; write .deputy/<slug>.fail.md and exit (the runner will recover the item). See #85/#86.\n' >&2
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
  local -a running=() pendmerge=() surfaced=() waiting=() paused=() deferred=() failcanc=() done_stream=()
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
    local _rg_prereq; _rg_prereq="$(_prereq_ids_from_line "$raw")"
    # Re-serialize each item so the canonical (current) symbols are written back —
    # this is what migrates pre-migration '#'/'>' lines to '+'/';' on regroup.
    # #114: pass prereq extracted from the raw line so the tag is never lost on regroup.
    norm="$(_serialize_item "$state" "$prio" "$id" "$desc" "$_rg_prereq")"
    case "$state" in
      running)                    running+=("$norm") ;;
      # #112: MUST have an arm here — this case has no default branch, so any state without
      # one is silently DROPPED from BACKLOG.md (the item vanishes on the next regroup).
      pending-merge)              pendmerge+=("$norm") ;;
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

  # Always emit all eight '### Section (N)' headers, in order, for a stable
  # skeleton — even when a section is empty. Done is last (bottom of file).
  # ORDER RATIONALE: grouped by WHO resolves it, then by how live it is.
  #   Running/Surfaced/Waiting/Deferred — what the human reads and acts on, kept
  #     adjacent so the queue you care about is one block, not interleaved.
  #   Paused/Pending merge — deputy resolves these ITSELF (paused auto-resumes via
  #     cmd_pick; pending-merge drains every tick and escalates to surfaced after
  #     merge_retry_strikes). Neither is in _ATTENTION_STATES, so neither ever asks
  #     for you — but both are still IN FLIGHT, so they sit ABOVE the terminal
  #     section rather than below it.
  #   Failed / Cancelled / Duplicate, then Done — terminal, nothing will move them.
  # Purely cosmetic: _each_item parses by LINE PREFIX, never by section, and
  # cmd_release anchors on the '### Done ' pattern — so this order is free to change.
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
    printf '\n### Deferred (%d)\n' "${#deferred[@]}" || _werr=1
    (( ${#deferred[@]} )) && { printf '%s\n' "${deferred[@]}" || _werr=1; }
    printf '\n### Paused (%d)\n' "${#paused[@]}" || _werr=1
    (( ${#paused[@]} )) && { printf '%s\n' "${paused[@]}" || _werr=1; }
    printf '\n### Pending merge (%d)\n' "${#pendmerge[@]}" || _werr=1
    (( ${#pendmerge[@]} )) && { printf '%s\n' "${pendmerge[@]}" || _werr=1; }
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
    # 10# forces base-10 so a zero-padded prefix ('[#08]') can't trip bash's octal arithmetic.
    if [[ "$_ai_id" =~ ^([0-9]+)(\.[0-9]+)?$ ]] && (( 10#${BASH_REMATCH[1]} > max_id )); then max_id=$(( 10#${BASH_REMATCH[1]} )); fi
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
    local _ai_prereq; _ai_prereq="$(_prereq_ids_from_line "$_ai_line")"
    if [[ -z "$_ai_id" ]]; then
      local _ai_state="${parsed%%|*}"
      local _ai_prio="${parsed#*|}"; _ai_prio="${_ai_prio%%|*}"
      local _ai_desc_rest="${parsed#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"; _ai_desc_rest="${_ai_desc_rest#*|}"
      # Items with no explicit priority get the default [P3] tag.
      [[ -z "$_ai_prio" ]] && _ai_prio="P3"
      local _ai_new_line
      # #114: preserve prereq tag when assigning a new ID.
      _ai_new_line="$(_serialize_item "$_ai_state" "$_ai_prio" "$next_id" "$_ai_desc_rest" "$_ai_prereq")"
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
        # #114: preserve prereq tag when backfilling priority.
        _ai_new_line="$(_serialize_item "$_ai_state" "P3" "$_ai_id" "$_ai_desc_rest" "$_ai_prereq")"
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
    [[ "$_ni_id" =~ ^([0-9]+)(\.[0-9]+)?$ ]] && (( 10#${BASH_REMATCH[1]} > max_id )) && max_id=$(( 10#${BASH_REMATCH[1]} ))
  done < <(_each_item)
  printf '%s' "$(( max_id + 1 ))"
}

# Echo the FIRST backlog item line whose PARSED id field equals <id> — an EXACT id match, so a
# description that merely mentions "[#<id>]" can never hijack the lookup, and a sub-id's '.' is
# compared literally (not as a regex wildcard). rc1 + no output if none. This mirrors the id
# resolution already used by `set`/`run`; the lifecycle paths (merge, retry-budget) use it in
# place of an unanchored `grep -F "[#$id]"`, which could otherwise flip the wrong line's state.
_line_by_id() {
  local want="$1" raw p rid
  [[ -n "$want" ]] || return 1
  while IFS= read -r raw; do
    p="$(_parse_item "$raw")"; rid="${p#*|}"; rid="${rid#*|}"; rid="${rid%%|*}"
    [[ "$rid" == "$want" ]] && { printf '%s' "$raw"; return 0; }
  done < <(_each_item)
  return 1
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
    if _valid_item_id "$_bs_id" && [[ -f "$STATE_DIR/proposed-$_bs_id" || -f "$STATE_DIR/ready-merge-$_bs_id" ]]; then
      continue   # a worker proposal (#53) or a ready-to-merge surface (#60) — not a blocking surface
    fi
    n=$(( n + 1 ))
  done < <(_each_item)
  printf '%s' "$n"
}

# ── #113: acceptance record — the falsifiable done-criterion ─────────────────
# WHY: deputy's `done` means steps committed + tests green + merged. NONE of that
# proves the REPORTED SYMPTOM is gone: the fixing agent writes the test, in the same
# step, AFTER writing the fix, and the reviewer reads the diff — so both artifacts are
# fitted to the implementation and neither ever sees what the human observed. The
# acceptance record freezes the symptom in the HUMAN's words at add time so `deputy
# verify` can later prove it was present before the fix and absent after.
#   observe: how to see it (command / query / click path) — becomes the red/green check
#   actual:  what happened — so a DIFFERENT failure is not mistaken for success
#   expect:  what should have happened — bounds "correct"
#   where:   environment + data — decides whether unit tests can see the bug at all
#   match:   OPTIONAL regex the failing output must match. `actual` is human prose and
#            cannot be checked mechanically; without `match`, red/bite score ANY nonzero
#            exit as "the symptom is present", so a blank column that becomes a thrown
#            exception still reads as the same bug. Set `match` when the difference matters.
# Stored at .deputy/accept/<slug>.md, keyed by the frozen slug (#99) so it survives
# every resume/rerun and can never be quietly redefined by the agent doing the work.
_accept_path() { _trail_path accept "$1"; }

# Placeholder written for a question the human skipped. Treated as "no criterion" by
# every gate, so a skipped answer never masquerades as a satisfied one.
_ACC_UNSET='(unspecified)'

# Collapse a value to a single line — the record is one `key: value` per line, and a
# flag-supplied newline would otherwise forge extra fields.
_acc_oneline() { printf '%s' "${1:-}" | tr '\n\r' '  ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'; }

# Read one field back out of an acceptance record (empty when absent/placeholder).
_accept_field() { # <file> <key>
  local v; v="$(sed -n "s/^$2: //p" "$1" 2>/dev/null | head -1)"
  [[ "$v" == "$_ACC_UNSET" ]] && return 0
  printf '%s' "$v"
}

# Resolve an <id-or-slug> argument to a slug. A bare item id maps through the frozen
# meta; anything else is already a slug.
_accept_slug_of() {
  local a="${1#\#}"
  if _valid_item_id "$a"; then cmd_slug "$a" 2>/dev/null | head -1; else printf '%s' "$a"; fi
}

# Cheap symptom heuristic: does this description READ like a bug report? Used ONLY to
# decide whether to grill an interactive human — never to block, reclassify, or gate an
# item. A false negative just means no prompt (pass --observe explicitly); a false
# positive costs four skippable questions.
_looks_like_bug() {
  local t; t="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
  [[ "$t" =~ (^|[^a-z])(fix|fixes|bug|broken|breaks|broke|fail|fails|failing|failure|error|errors|crash|crashes|wrong|incorrect|blank|missing|regression|regressed|stuck|hang|hangs|throws|throwing|exception|traceback|timeout|nan|null|undefined|mismatch|garbled|duplicated|stale)([^a-z]|$) ]] && return 0
  case "$t" in
    *"doesn't"*|*"does not"*|*"not working"*|*"no longer"*|*"isn't"*|*"is not"*|*"can't"*|*"cannot"*|*"won't"*) return 0 ;;
  esac
  return 1
}

# Interactive grill for the four fields. Assigns into the CALLER's _ACC_* variables
# (bash dynamic scoping — never call this from a subshell or the answers are lost).
# The caller guarantees both stdin and stdout are a terminal before calling: a pipe,
# a test, cron, or a headless worker must never block here on input that never comes.
_accept_grill() {
  local _desc="$1" _a
  printf '\n' >&2
  printf 'deputy: "%s" reads like a bug report.\n' "$_desc" >&2
  printf '  A merged, tested, all-green fix still does not prove your symptom is gone —\n' >&2
  printf '  deputy needs to see the symptom itself to prove that. Four short answers:\n' >&2
  printf '  (Enter skips one; skip all four and deputy records that it cannot verify this.)\n\n' >&2
  printf '  OBSERVE  how do you see it? (a command, query, or click path)\n  > ' >&2
  read -r _a || { printf '\n' >&2; return 1; }; _ACC_OBSERVE="$(_acc_oneline "$_a")"
  printf '  ACTUAL   what happened? (the wrong output — verbatim if you have it)\n  > ' >&2
  read -r _a || { printf '\n' >&2; return 0; }; _ACC_ACTUAL="$(_acc_oneline "$_a")"
  printf '  EXPECT   what should have happened instead?\n  > ' >&2
  read -r _a || { printf '\n' >&2; return 0; }; _ACC_EXPECT="$(_acc_oneline "$_a")"
  printf '  WHERE    which environment + data? (prod/local, which dataset)\n  > ' >&2
  read -r _a || { printf '\n' >&2; return 0; }; _ACC_WHERE="$(_acc_oneline "$_a")"
  printf '\n' >&2
  return 0
}

# Persist the record for <id>, merging over any existing one (so a partial update never
# blanks a field the human already answered). Echoes the path on success.
_write_accept_record() { # <id>
  local id="$1" slug f
  slug="$(_accept_slug_of "$id")"
  [[ -n "$slug" ]] || return 1
  # Reject anything that is not a plain slug — the value reaches a filesystem path, so a
  # '/' or '..' component must never be able to steer the write out of .deputy/accept/.
  _wp_validate_id "$slug" || return 1
  f="$(_accept_path "$slug")"
  # The read-modify-write must be atomic against a concurrent `accept`/`add --observe` on
  # the same item, or a partial update silently drops the field the other writer set.
  _do_accept_write() {
    local o a e w m tmp
    if [[ -f "$f" ]]; then
      o="$(_accept_field "$f" observe)"; a="$(_accept_field "$f" actual)"
      e="$(_accept_field "$f" expect)";  w="$(_accept_field "$f" where)"
      m="$(_accept_field "$f" match)"
    fi
    [[ -n "${_ACC_OBSERVE:-}" ]] && o="$_ACC_OBSERVE"
    [[ -n "${_ACC_ACTUAL:-}"  ]] && a="$_ACC_ACTUAL"
    [[ -n "${_ACC_EXPECT:-}"  ]] && e="$_ACC_EXPECT"
    [[ -n "${_ACC_WHERE:-}"   ]] && w="$_ACC_WHERE"
    [[ -n "${_ACC_MATCH:-}"   ]] && m="$_ACC_MATCH"
    tmp="$f.tmp.$$"
    { printf '# Acceptance — #%s\n' "$id"
      printf '# The reported symptom, in the reporter'"'"'s words, frozen at add time.\n'
      printf '# A fix is proven only when `observe` FAILS before it and PASSES after\n'
      printf '# (deputy verify --red / --green / --bite).\n\n'
      printf 'observe: %s\n' "${o:-$_ACC_UNSET}"
      printf 'actual: %s\n'  "${a:-$_ACC_UNSET}"
      printf 'expect: %s\n'  "${e:-$_ACC_UNSET}"
      printf 'where: %s\n'   "${w:-$_ACC_UNSET}"
      printf 'match: %s\n'   "${m:-$_ACC_UNSET}"
      printf 'recorded-at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  }
  _with_lock _do_accept_write || return 1
  printf '%s' "$f"
}

# `deputy accept <id|slug> [--observe .. --actual .. --expect .. --where ..]`
# No flags → print the record. With flags → create/update it (backfill for items added
# before this existed, or for one the heuristic did not flag).
cmd_accept() {
  local a="${1:-}"
  [[ -n "$a" ]] || { printf 'deputy: accept requires an <id> or <slug>\n' >&2; return 2; }
  shift
  local _ACC_OBSERVE="" _ACC_ACTUAL="" _ACC_EXPECT="" _ACC_WHERE="" _ACC_MATCH="" _w=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --observe) [[ $# -ge 2 ]] || { printf 'deputy: accept --observe needs a value\n' >&2; return 2; }; _ACC_OBSERVE="$(_acc_oneline "$2")"; _w=1; shift 2 ;;
    --actual)  [[ $# -ge 2 ]] || { printf 'deputy: accept --actual needs a value\n'  >&2; return 2; }; _ACC_ACTUAL="$(_acc_oneline "$2")";  _w=1; shift 2 ;;
    --expect)  [[ $# -ge 2 ]] || { printf 'deputy: accept --expect needs a value\n'  >&2; return 2; }; _ACC_EXPECT="$(_acc_oneline "$2")";  _w=1; shift 2 ;;
    --where)   [[ $# -ge 2 ]] || { printf 'deputy: accept --where needs a value\n'   >&2; return 2; }; _ACC_WHERE="$(_acc_oneline "$2")";   _w=1; shift 2 ;;
    --match)   [[ $# -ge 2 ]] || { printf 'deputy: accept --match needs a value\n'   >&2; return 2; }; _ACC_MATCH="$(_acc_oneline "$2")";   _w=1; shift 2 ;;
    *) printf 'deputy: accept: unexpected arg: %s\n' "$1" >&2; return 2 ;;
  esac; done
  local slug; slug="$(_accept_slug_of "$a")"
  [[ -n "$slug" ]] || { printf 'deputy: accept: no task %s\n' "$a" >&2; return 1; }
  # The slug becomes a path under .deputy/accept/ — never let a '/' or '..' through.
  _wp_validate_id "$slug" || return 2
  if [[ "$_w" -eq 1 ]]; then
    local f; f="$(_write_accept_record "${a#\#}")" \
      || { printf 'deputy: accept: could not write the acceptance record for %s\n' "$a" >&2; return 1; }
    printf 'deputy: acceptance recorded → %s\n' "$f"
    return 0
  fi
  local f; f="$(_accept_path "$slug")"
  [[ -f "$f" ]] || {
    printf 'deputy: accept: no acceptance record for %s — deputy cannot prove a fix works on it.\n' "$a" >&2
    printf '  add one:  deputy accept %s --observe "<how to see it>" --actual "<what happens>" --expect "<what should>" --where "<env+data>"\n' "${a#\#}" >&2
    return 1; }
  cat "$f"
}

cmd_add() {
  # Priority flags: -ui/-u/-i (urgent+important / urgent / important) are aliases
  # for --p0/--p1/--p2. A `--` marker ends flag parsing so a description may begin
  # with a dash (e.g. `deputy add -- "-5% drop alert"`). Last flag wins.
  local text="" prio="" no_more_flags=0
  # #113: acceptance fields may be supplied non-interactively (scripts, CI, an agent
  # filing a proposal); --no-accept opts a chore out of the grill entirely.
  local _ACC_OBSERVE="" _ACC_ACTUAL="" _ACC_EXPECT="" _ACC_WHERE="" _ACC_MATCH="" _acc_skip=0
  while [[ $# -gt 0 ]]; do
    if [[ "$no_more_flags" -eq 0 ]]; then
      case "$1" in
        --)         no_more_flags=1; shift; continue ;;
        --p0|-ui)   prio=P0; shift; continue ;;
        --p1|-u)    prio=P1; shift; continue ;;
        --p2|-i)    prio=P2; shift; continue ;;
        --p3)       prio=P3; shift; continue ;;
        --p4)       prio=P4; shift; continue ;;
        --observe)  [[ $# -ge 2 ]] || { printf 'deputy: add --observe needs a value\n' >&2; return 2; }; _ACC_OBSERVE="$(_acc_oneline "$2")"; shift 2; continue ;;
        --actual)   [[ $# -ge 2 ]] || { printf 'deputy: add --actual needs a value\n'  >&2; return 2; }; _ACC_ACTUAL="$(_acc_oneline "$2")";  shift 2; continue ;;
        --expect)   [[ $# -ge 2 ]] || { printf 'deputy: add --expect needs a value\n'  >&2; return 2; }; _ACC_EXPECT="$(_acc_oneline "$2")";  shift 2; continue ;;
        --where)    [[ $# -ge 2 ]] || { printf 'deputy: add --where needs a value\n'   >&2; return 2; }; _ACC_WHERE="$(_acc_oneline "$2")";   shift 2; continue ;;
        --match)    [[ $# -ge 2 ]] || { printf 'deputy: add --match needs a value\n'   >&2; return 2; }; _ACC_MATCH="$(_acc_oneline "$2")";   shift 2; continue ;;
        --no-accept) _acc_skip=1; shift; continue ;;
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
        "$_pfx" == ';' || "$_pfx" == '&' || "$_pfx" == '#' || "$_pfx" == '>' ]] || [[ "$text" =~ ^\[(P[0-4]|#[0-9]+)\] ]]; then
    printf 'deputy: description may not begin with a status prefix (~@?+!%%=^;& legacy #>) or a tag ([Px] or [#N]): %s\n' "$text" >&2
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
  # #113: grill for the acceptance record BEFORE the item is written — `add` may autorun a
  # worker on the new item at the end of this function, so the criterion must already exist
  # when that worker starts. Grill ONLY a human at a real terminal: a pipe, a test, cron, or
  # a headless worker would block forever on a read that never gets an answer.
  local _acc_given=0
  [[ -n "$_ACC_OBSERVE$_ACC_ACTUAL$_ACC_EXPECT$_ACC_WHERE$_ACC_MATCH" ]] && _acc_given=1
  if [[ "$_acc_skip" -eq 0 && "$_worker" -eq 0 && "${DEPUTY_NO_GRILL:-0}" != "1" ]] \
     && [[ "$(_config_get accept_grill)" != "0" ]] && _looks_like_bug "$text"; then
    if [[ -t 0 && -t 1 ]]; then
      _accept_grill "$text" || true
      [[ -n "$_ACC_OBSERVE$_ACC_ACTUAL$_ACC_EXPECT$_ACC_WHERE$_ACC_MATCH" ]] && _acc_given=1
    elif [[ "$_acc_given" -eq 0 ]]; then
      # Never block a non-interactive caller — but never let the gap be silent either.
      printf 'deputy: note: "%s" reads like a bug but carries no acceptance record, so deputy cannot prove the symptom is gone.\n' "$text" >&2
      printf '  add one with: deputy accept <id> --observe "<how to see it>" --actual "<what happens>" --expect "<what should>" --where "<env+data>"\n' >&2
    fi
  fi
  rm -f "$STATE_DIR/.proposed_pending.$$" "$STATE_DIR/.add_pending.$$" 2>/dev/null || true
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
      # #99: freeze the immutable user_desc + canonical slug FIRST (required) — a task must
      # never exist without its frozen slug. Roll the meta back if the append then fails.
      _write_task_meta "$_nid" "$text" || { printf 'deputy: add: could not persist task metadata (#%s) — not added\n' "$_nid" >&2; return 1; }
      _append_item "$(_serialize_item surfaced "$_pprio" "$_nid" "$text")" || { rm -f "$(_meta_path "$_nid")" 2>/dev/null || true; return 1; }
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
    # Eagerly assign the id (so the output can name it), applying the P3 default now,
    # exactly as _allocate_ids would for an un-prioritized item.
    local _nid _pprio; _nid="$(_next_id)"; _pprio="${prio:-P3}"
    [[ "$_nid" =~ ^[0-9]+$ ]] || { printf 'deputy: id allocation failed\n' >&2; return 1; }
    # #99: freeze the immutable user_desc + canonical slug FIRST (required); roll back on append fail.
    _write_task_meta "$_nid" "$text" || { printf 'deputy: add: could not persist task metadata (#%s) — not added\n' "$_nid" >&2; return 1; }
    _append_item "$(_serialize_item waiting "$_pprio" "$_nid" "$text")" || { rm -f "$(_meta_path "$_nid")" 2>/dev/null || true; return 1; }
    # #105: hand the NEW id across the _with_lock subshell ($$ is stable) so the disposition
    # message below fires ONLY for a genuinely-new item (never a duplicate 'already present').
    printf '%s' "$_nid" > "$STATE_DIR/.add_pending.$$" 2>/dev/null || true
    printf 'deputy: added #%s: %s\n' "$_nid" "$text"
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
  # #113: persist the acceptance record for a genuinely-NEW item. Either handoff file
  # carries the new id; a duplicate ("already present") wrote neither, so an add that
  # matched an existing item never overwrites that item's frozen criterion.
  if [[ "$_acc_given" -eq 1 ]]; then
    local _acc_id _acc_f
    _acc_id="$(cat "$STATE_DIR/.proposed_pending.$$" 2>/dev/null || cat "$STATE_DIR/.add_pending.$$" 2>/dev/null || true)"
    if _valid_item_id "${_acc_id:-}"; then
      if _acc_f="$(_write_accept_record "$_acc_id")" && [[ -n "$_acc_f" ]]; then
        printf 'deputy: acceptance recorded → %s\n' "$_acc_f"
      else
        printf 'deputy: warning: could not write the acceptance record for #%s\n' "$_acc_id" >&2
      fi
    fi
  fi
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
  # #105: capture the NEW item's id (handoff from _do_add across its _with_lock subshell; $$ is
  # stable). Read + delete it unconditionally so it never leaks (e.g. under DEPUTY_NO_AUTORUN=1),
  # and so it fires ONLY for a genuinely-new item — a duplicate 'already present' wrote nothing.
  local _np_id; _np_id="$(cat "$STATE_DIR/.add_pending.$$" 2>/dev/null || true)"
  rm -f "$STATE_DIR/.add_pending.$$" 2>/dev/null || true
  # Trigger execution immediately if nothing is running and work is available.
  # Set DEPUTY_NO_AUTORUN=1 to suppress (used in tests that exercise add in isolation).
  if [[ "${DEPUTY_NO_AUTORUN:-0}" != "1" ]] && ! _live_claim_exists && [[ -n "$(cmd_pick)" ]]; then
    # Make the just-added task's priority disposition OBSERVABLE (behavior unchanged — _autorun
    # still drains the globally highest-priority runnable task; idle here, within #105's "no
    # running task" scope). Consistent with `run --<prio>`'s messages (#104).
    if [[ "$_np_id" =~ ^[0-9]+$ ]]; then
      local _np_prio _np_top _np_top_id; _np_prio="${prio:-P3}"
      _np_top="$(cmd_pick)"; _np_top_id="$(_parse_item "$_np_top")"
      _np_top_id="${_np_top_id#*|}"; _np_top_id="${_np_top_id#*|}"; _np_top_id="${_np_top_id%%|*}"
      # Phrased as state (not a promise that this exact item runs): a concurrent add/set could
      # change the top between here and _autorun, since this runs after the queue lock releases.
      if [[ "$_np_top_id" == "$_np_id" ]]; then
        printf 'deputy: #%s (%s) is currently the highest-priority runnable task — running the queue now.\n' "$_np_id" "$_np_prio"
      else
        printf 'deputy: #%s (%s) queued — equal-or-higher-priority items waiting.\n' "$_np_id" "$_np_prio"
      fi
    fi
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
  local raw state w=0 t=0 r=0 s=0 d=0 f=0 c=0 u=0 p=0 df=0 pm=0 parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting) w=$((w+1)) ;; triaging) t=$((t+1)) ;; running)    r=$((r+1)) ;;
      surfaced) s=$((s+1)) ;; done) d=$((d+1)) ;;    failed)     f=$((f+1)) ;;
      cancelled) c=$((c+1)) ;; duplicate) u=$((u+1)) ;; paused)  p=$((p+1)) ;;
      pending-merge) pm=$((pm+1)) ;;
      deferred) df=$((df+1)) ;;
    esac
  done < <(_each_item)
  printf 'waiting:  %d\ntriaging: %d\nrunning:  %d\nsurfaced: %d\npending-merge: %d\ndone:     %d\nfailed:   %d\ncancelled: %d\nduplicate: %d\npaused:   %d\ndeferred: %d\n' \
    "$w" "$t" "$r" "$s" "$pm" "$d" "$f" "$c" "$u" "$p" "$df"
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
  local nw=0 npa=0 nd=0 npm=0
  local -a rows=()
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    case "$state" in
      waiting)  grp=0; nw=$((nw+1)) ;;
      paused)   grp=0; npa=$((npa+1)) ;;
      deferred) grp=1; nd=$((nd+1)) ;;
      # #112: not runnable, but shown so a parked merge is never invisible — it just is
      # never something the human is asked to action.
      pending-merge) grp=2; npm=$((npm+1)) ;;
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
    printf 'Queue: empty (no waiting, paused, deferred, or pending-merge items).\n'
    return 0
  fi
  printf 'Queue — %d waiting, %d paused, %d deferred, %d pending-merge:\n' "$nw" "$npa" "$nd" "$npm"
  printf '%-13s %-4s %-6s %s\n' 'STATE' 'PRI' 'ID' 'TASK'
  # sort by group (runnable<deferred), then rank, then file index (FIFO ties);
  # drop the 3 sort-key columns and render the remaining 4 as aligned columns.
  printf '%s\n' "${rows[@]}" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n \
    | cut -f4- \
    | while IFS="$(printf '\t')" read -r st pr id_col task; do
        printf '%-13s %-4s %-6s %s\n' "$st" "$pr" "$id_col" "$task"
      done
}

cmd_pick() {
  _with_lock _allocate_ids
  # #114 — transitive priority inheritance + prereq gate.
  # Phase 1: collect all items; compute initial one-hop boost (blocked item → direct prereq).
  # Phase 2: fixpoint iteration — propagate effective rank down the chain until stable.
  # Phase 3: pick the highest-effective-rank item whose own prereqs are satisfied.
  local raw parsed state prio id rank _cp_sat _cp_pcsv
  local -a _cp_raws=() _cp_states=() _cp_ids=() _cp_ranks=() _cp_sats=() _cp_pcsvs=()
  declare -A _cp_boost   # id → min(rank) seen in its blocked subtree (lower = higher prio)

  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    id="${parsed#*|}"; id="${id#*|}"; id="${id%%|*}"
    rank="$(_prio_rank "$prio")"
    _cp_sat=1; _prereqs_satisfied_for_line "$raw" || _cp_sat=0
    _cp_pcsv=""
    [[ "$_cp_sat" -eq 0 ]] && _cp_pcsv="$(_prereq_ids_from_line "$raw")"
    _cp_raws+=("$raw"); _cp_states+=("$state")
    _cp_ids+=("$id"); _cp_ranks+=("$rank"); _cp_sats+=("$_cp_sat"); _cp_pcsvs+=("$_cp_pcsv")
    # One-hop boost: blocked item propagates its own rank to each direct prereq.
    if [[ "$state" == "waiting" || "$state" == "paused" ]] && [[ "$_cp_sat" -eq 0 ]] && [[ -n "$_cp_pcsv" ]]; then
      local _cp_prid _cp_cur
      while IFS= read -r _cp_prid; do
        [[ -z "$_cp_prid" ]] && continue
        _cp_cur="${_cp_boost[$_cp_prid]:-99}"
        (( rank < _cp_cur )) && _cp_boost[$_cp_prid]=$rank
      done <<< "${_cp_pcsv//,/$'\n'}"
    fi
  done < <(_each_item)

  # Fixpoint: if a boosted blocked item B has its own prereqs, propagate B's effective
  # rank (min of B's own rank and boost) to B's prereqs — handles chains like D→B→A
  # where D(P0) must eventually boost A, not just B.
  local _cp_changed=1 i
  while [[ "$_cp_changed" -eq 1 ]]; do
    _cp_changed=0
    for i in "${!_cp_raws[@]}"; do
      [[ "${_cp_sats[$i]}" -eq 1 ]] && continue   # not blocked — nothing to propagate
      # Only waiting/paused items can become runnable; don't route boosts through terminals.
      [[ "${_cp_states[$i]}" == "waiting" || "${_cp_states[$i]}" == "paused" ]] || continue
      id="${_cp_ids[$i]}"
      [[ -z "${_cp_boost[$id]+x}" ]] && continue  # no boost received yet — skip
      local _cp_eff="${_cp_boost[$id]}" _cp_r="${_cp_ranks[$i]}"
      (( _cp_r < _cp_eff )) && _cp_eff=$_cp_r    # effective = min(own rank, boost)
      local _cp_pcsv2="${_cp_pcsvs[$i]:-}"
      [[ -z "$_cp_pcsv2" ]] && continue
      local _cp_prid2 _cp_cur2
      while IFS= read -r _cp_prid2; do
        [[ -z "$_cp_prid2" ]] && continue
        _cp_cur2="${_cp_boost[$_cp_prid2]:-99}"
        if (( _cp_eff < _cp_cur2 )); then
          _cp_boost[$_cp_prid2]=$_cp_eff; _cp_changed=1
        fi
      done <<< "${_cp_pcsv2//,/$'\n'}"
    done
  done

  local best_rank=99 best_line="" _eff
  for i in "${!_cp_raws[@]}"; do
    state="${_cp_states[$i]}"
    [[ "$state" == "waiting" || "$state" == "paused" ]] || continue
    [[ "${_cp_sats[$i]}" -eq 1 ]] || continue   # skip items blocked by unmet prereqs
    id="${_cp_ids[$i]}"
    rank="${_cp_ranks[$i]}"
    # Effective rank = min(own rank, rank inherited from highest-priority blocked descendant).
    _eff="${_cp_boost[$id]:-$rank}"
    (( rank < _eff )) && _eff=$rank   # own rank caps effective (can't boost worse than self)
    if (( _eff < best_rank )); then
      best_rank=$_eff; best_line="${_cp_raws[$i]}"
    fi
  done
  [[ -n "$best_line" ]] && printf '%s\n' "$best_line"
  return 0
}

_valid_state() {
  case "$1" in waiting|triaging|running|surfaced|done|failed|cancelled|duplicate|paused|deferred|pending-merge) return 0 ;; *) return 1 ;; esac
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
  # #69: an optional leading 'prio'|'state' keyword selects what to change. Default is
  # 'state', so the existing whole-line form `deputy set "<line>" <state>` (the headless
  # worker's contract) is unchanged. 'prio' re-prioritizes IN PLACE (state untouched).
  # Only consume a leading prio|state keyword in the unambiguous 3-arg form
  # (`set <kw> <line> <value>`); the 2-arg form `set <line> <state>` is NEVER
  # reinterpreted, so the whole-line worker contract is exactly preserved. Use
  # ${1:-} so a no-arg `deputy set` hits the usage check, not a set -u crash.
  local action="state"
  if [[ "$#" -ge 3 && ( "${1:-}" == "prio" || "${1:-}" == "state" ) ]]; then action="$1"; shift; fi
  local from="${1:-}" newval="${2:-}"
  [[ -n "$from" && -n "$newval" ]] || { printf 'deputy: set [prio|state] <id|"<line>"> <state|pN>\n' >&2; return 2; }
  # Shape-based unification: a bare value of p0..p4 means a PRIORITY change even without
  # the explicit 'prio' keyword ('deputy set #5 p0'). Ids are #-prefixed and states are
  # words, so a pN value is unambiguous. The headless worker whole-line contract always
  # passes a STATE value (never pN), so this never reinterprets it.
  if [[ "$action" == "state" && "$newval" =~ ^[pP][0-4]$ ]]; then action="prio"; fi
  # #60: --ready-merge marks a 'surfaced' item as "branch ready for human merge-review"
  # (distinct from a blocked surface) so it's excluded from the blocking-surfaced count.
  local _ready_merge=0 _rm_branch="" _rm_branch_seen=0 _a
  for _a in "${@:3}"; do          # flags only AFTER <line> <value> — never the line/desc itself
    case "$_a" in
      --ready-merge) _ready_merge=1 ;;
      # #97: the worker records the EXACT branch it built (deputy/<slug>) — deterministic and
      # independent of whether .deputy/wt is still live at surface time (a resumed run that
      # skips wt-create has no live worktree, so a rev-parse would silently record nothing).
      --branch) printf 'deputy: set: --branch requires a value (use --branch=<ref>)\n' >&2; return 2 ;;
      --branch=*) _rm_branch="${_a#--branch=}"; _rm_branch_seen=1 ;;
      *) printf 'deputy: set: unknown argument: %s\n' "$_a" >&2; return 2 ;;
    esac
  done
  # #98: an EXPLICIT --branch must be valid — fail fast (return 2) rather than silently
  # recording a no-branch marker that would sit surfaced forever. Gate on _rm_branch_seen (not
  # -n "$_rm_branch") so an explicit empty --branch= is rejected too, not treated as absent.
  # (The live-worktree fallback below, used only when NO --branch is passed, stays best-effort —
  # the runner's unique-branch recovery covers it.) Validate before any state flip.
  if [[ "$_rm_branch_seen" -eq 1 ]]; then
    [[ "$_rm_branch" == deputy/* ]] || { printf 'deputy: set: --branch must be a deputy/* ref: %s\n' "$_rm_branch" >&2; return 2; }
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$_rm_branch" 2>/dev/null || { printf 'deputy: set: --branch does not exist: %s\n' "$_rm_branch" >&2; return 2; }
  fi
  if [[ "$action" == "prio" ]]; then
    [[ "$newval" =~ ^[pP][0-4]$ ]] || { printf 'deputy: set: invalid priority: %s (expected p0..p4)\n' "$newval" >&2; return 2; }
  else
    _valid_state "$newval" || { printf 'deputy: invalid state: %s\n' "$newval" >&2; return 2; }
  fi
  # #56: accept an item id (N or #N) as the <line> arg, for parity with `run #N` /
  # `clean N`. Only when 'from' is NOT already a literal backlog line (whole-line form
  # always wins, so a legacy numeric raw line is unaffected) and looks like an id, resolve
  # it to THE line by parsed id field (robust vs description text that contains "[#N]").
  # Resolved here so the post-lock notify + marker-cleanup parse the real line; _do_set's
  # under-lock grep -qxF re-validates, so a line that moved meanwhile errors cleanly.
  if _valid_item_id "${from#'#'}" && ! grep -qxF -- "$from" "$BACKLOG" 2>/dev/null; then
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
    local parsed curr_state prio desc to _id_rest _id _eff_state
    parsed="$(_parse_item "$from")"
    curr_state="${parsed%%|*}"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    _id_rest="${parsed#*|}"; _id_rest="${_id_rest#*|}"; _id="${_id_rest%%|*}"
    desc="${_id_rest#*|}"
    # #114: preserve prereq tag across state/prio changes.
    local _ds_prereq; _ds_prereq="$(_prereq_ids_from_line "$from")"
    # #69: 'prio' keeps the current state and rewrites the [Px] tag; 'state' (default)
    # keeps the priority and rewrites the state — the original behavior. _eff_state is
    # the RESULTING state (current state for a prio change), used for the #60 marker.
    if [[ "$action" == "prio" ]]; then
      local _np; _np="$(printf '%s' "$newval" | tr 'a-z' 'A-Z')"
      to="$(_serialize_item "$curr_state" "$_np" "$_id" "$desc" "$_ds_prereq")"
      _eff_state="$curr_state"
    else
      to="$(_serialize_item "$newval" "$prio" "$_id" "$desc" "$_ds_prereq")"
      _eff_state="$newval"
    fi
    # Propagate a write failure: a swallowed rc here would let the trailing #60 marker
    # block (which returns 0) mask a failed line flip, so 'set' would falsely report success.
    # Preserve the EXACT rc (#86): _flip_line returns 3 on an unrecoverable BACKLOG write,
    # which the worker keys on to fail-fast — collapsing it to 1 would lose that contract.
    # #112: pending-merge is only reachable for an item whose branch is KNOWN. The drain
    # resolves it from the ready-merge-<id> marker (or the unique-branch fallback); with
    # neither, parking the item would strand it in a state nothing can ever complete.
    if [[ "$_eff_state" == "pending-merge" ]] && _valid_item_id "$_id"; then
      local _pm_br; _pm_br="$(_ready_merge_branch "$_id" 2>/dev/null || true)"
      if [[ "$_pm_br" != deputy/* ]]; then
        printf 'deputy: refusing to set #%s pending-merge — no ready-merge marker and no unique deputy/* branch to merge (surface it instead)\n' "$_id" >&2
        return 2
      fi
    fi
    local _fl_rc; _flip_line "$from" "$to"; _fl_rc=$?; [[ "$_fl_rc" -eq 0 ]] || return "$_fl_rc"
    # #60: maintain the ready-merge marker under the SAME lock as the line flip, so scheduling
    # never sees a 'surfaced' item without its marker (no blocking-count race window).
    if _valid_item_id "$_id"; then
      if [[ "$_eff_state" == "surfaced" && "$_ready_merge" == "1" ]]; then
        # Record the EXACT branch (#97) so the runner's auto-merge never has to guess it. Prefer
        # the branch the worker passed explicitly (--branch=deputy/<slug>) — deterministic and
        # valid even when .deputy/wt is gone (e.g. a resumed run that skipped wt-create). Fall
        # back to the live worktree's HEAD only when no branch was passed (older callers). A
        # recorded branch must both look like deputy/* AND actually exist as a local ref.
        local _rm_br="$_rm_branch"   # explicit --branch: already validated above (deputy/* + ref exists)
        if [[ -z "$_rm_br" ]]; then  # no --branch: best-effort read from the live worktree, validated
          _rm_br="$(git -C "$(_wt_path)" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
          [[ "$_rm_br" == deputy/* ]] && git -C "$ROOT" show-ref --verify --quiet "refs/heads/$_rm_br" 2>/dev/null || _rm_br=""
        fi
        { printf 'ready-merge-at: %s\nbranch ready for human merge-review\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          [[ -n "$_rm_br" ]] && printf 'branch: %s\n' "$_rm_br"; } > "$STATE_DIR/ready-merge-$_id" 2>/dev/null || true
      elif [[ "$_eff_state" != "surfaced" && "$_eff_state" != "pending-merge" ]]; then
        # #112: pending-merge KEEPS its marker — that marker is the only record of which
        # branch to merge, and the runner's drain re-reads it on every later tick. Dropping
        # it here would strand the item with an unresolvable branch, forever.
        rm -f "$STATE_DIR/ready-merge-$_id" 2>/dev/null || true
      fi
    fi
    # #67: if THIS transition moves the agent's own claimed item out of 'running',
    # release the agent claim + active-run now (under the same lock) so the slot frees
    # immediately rather than waiting out the heartbeat TTL. Match only our own agent
    # claim ($PPID.claim, owner=agent) whose claimed line is the one we just flipped.
    if [[ "$curr_state" == "running" && "$_eff_state" != "running" ]]; then
      local _ac="$STATE_DIR/$PPID.claim"
      if [[ -e "$_ac" && "$(sed -n '3p' "$_ac" 2>/dev/null || true)" == "agent" \
            && "$(sed -n '1p' "$_ac" 2>/dev/null || true)" == "$from" ]]; then
        rm -f "$_ac" 2>/dev/null || true
        if [[ "$(sed -n '1p' "$ACTIVE_RUN_DIR/owner" 2>/dev/null || true)" == "agent" \
              && "$(sed -n '1p' "$ACTIVE_RUN_DIR/pid" 2>/dev/null || true)" == "$PPID" ]]; then
          rm -rf "$ACTIVE_RUN_DIR" 2>/dev/null || true
        fi
      fi
    fi
  }
  local _set_rc=0
  _with_lock _do_set || _set_rc=$?
  if [[ "$_set_rc" -eq 0 ]]; then
    if [[ "$action" == "prio" ]]; then _commit_queue "set prio $newval"; else _commit_queue "set $newval"; fi
    local _parsed _desc _id_rest2 _eff_state2
    _parsed="$(_parse_item "$from")"
    _id_rest2="${_parsed#*|}"; _id_rest2="${_id_rest2#*|}"; _desc="${_id_rest2#*|}"
    # The resulting state: unchanged (current) for a prio change, else the new state.
    if [[ "$action" == "prio" ]]; then _eff_state2="${_parsed%%|*}"; else _eff_state2="$newval"; fi
    # #53: once a proposal (surfaced) is approved (->waiting), rejected (->cancelled),
    # or otherwise leaves surfaced, its .deputy/proposed-<id> marker is obsolete. The
    # rm is a no-op for non-proposal items (no marker). Skip while staying surfaced.
    if [[ "$_eff_state2" != "surfaced" ]]; then
      local _ps_id="${_id_rest2%%|*}"
      _valid_item_id "$_ps_id" && rm -f "$STATE_DIR/proposed-$_ps_id" 2>/dev/null || true
    fi
    # #69: a prio change is not a lifecycle transition — skip the notify + done-queue
    # print (those belong to state changes only).
    if [[ "$action" == "state" ]]; then
      # Background by default so slow channels (e.g. push/curl) don't block the CLI.
      # Set DEPUTY_NOTIFY_SYNC=1 to run synchronously (used in tests).
      if [[ "${DEPUTY_NOTIFY_SYNC:-0}" == "1" ]]; then
        _notify "$newval" "$_desc" >/dev/null 2>&1 || true
      else
        _notify "$newval" "$_desc" >/dev/null 2>&1 &
      fi
      # On a completion, show what's left. Done-only by design: a task is "completed"
      # only when done — failures (which transition via internal _do_set_item_failed,
      # not cmd_set) intentionally do not print the queue. In autonomous runs the
      # orchestrator's `deputy set <line> done` stdout is captured + relayed by the
      # run loop, so this single call covers both interactive and autonomous paths.
      if [[ "$newval" == "done" ]]; then
        _print_waiting_queue
      fi
      # #114: when an item becomes failed, surface any waiting/paused dependents whose
      # prereq graph goes through it — they can never become runnable.
      if [[ "$newval" == "failed" ]]; then
        _surface_blocked_by_failed "${_id_rest2%%|*}"
      fi
    fi
  fi
  return "$_set_rc"
}

# Get the start-time of a pid using ps lstart (portable; empty if unavailable).
_pid_start_time() {
  local pid="$1"
  ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true
}

# True (0) if the single claim file $1 is LIVE. The one place the liveness rule lives,
# reused by _live_claim_exists and cmd_recover. Claim file format:
#   Line 1: running item line   Line 2: PID start-time (optional)
#   Line 3: owner (run|targeted|agent)   Line 4: heartbeat epoch (agent only)
# Rule: an #67 agent claim (line3=agent) is live while its line-4 heartbeat is fresh
# (< 2x heartbeat_mins) even with a dead PID; otherwise (and for non-agent claims) it
# is live only if the pid exists (kill -0) AND the start-time matches — so it auto-EXPIRES.
_claim_live() {
  local f="$1" cpid owner last_hb hb ttl_sec now recorded_start actual_start
  cpid="${f##*/}"; cpid="${cpid%.claim}"
  [[ "$cpid" =~ ^[0-9]+$ ]] || return 1
  owner="$(sed -n '3p' "$f" 2>/dev/null || true)"
  if [[ "$owner" == "agent" ]]; then
    # Agent liveness is heartbeat-ONLY: the agent is not one long-lived process, so
    # there is no meaningful PID to kill -0. Fresh heartbeat → live; stale/missing →
    # EXPIRED (return, never fall through to a PID check that could read a reused pid).
    last_hb="$(sed -n '4p' "$f" 2>/dev/null || true)"
    if [[ "$last_hb" =~ ^[0-9]+$ ]]; then
      hb="$(_config_get heartbeat_mins)"; hb="${hb:-10}"; _valid_positive_int "$hb" || hb=10
      ttl_sec=$(( hb * 60 * 2 )); now="$(date +%s)"
      [[ "$last_hb" -le "$now" && $(( now - last_hb )) -lt "$ttl_sec" ]] && return 0  # reject future ts
    fi
    return 1
  fi
  kill -0 "$cpid" 2>/dev/null || return 1
  recorded_start="$(sed -n '2p' "$f" 2>/dev/null || true)"
  if [[ -n "$recorded_start" ]]; then
    actual_start="$(_pid_start_time "$cpid")"
    [[ "$actual_start" == "$recorded_start" ]] || return 1
  fi
  return 0
}

# True if ANY .deputy/<pid>.claim is live (see _claim_live).
_live_claim_exists() {
  local f
  for f in "$STATE_DIR"/*.claim; do
    [[ -e "$f" ]] || continue
    _claim_live "$f" && return 0
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
  local from="" pid="$PPID" owner="run"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid) [[ $# -gt 1 ]] || { printf 'deputy: --pid requires an argument\n' >&2; return 2; }; pid="$2"; shift 2 ;;
      --agent) owner="agent"; shift ;;   # #67: agent-shaped claim (heartbeat-TTL liveness)
      *) [[ -z "$from" ]] && { from="$1"; shift; } || { printf 'deputy: unexpected arg: %s\n' "$1" >&2; return 2; } ;;
    esac
  done
  [[ -n "$from" ]] || { printf 'deputy: claim requires "<line>"\n' >&2; return 2; }
  # #67: an agent claim is ALWAYS keyed on the orchestrator ($PPID) so the spine-verb
  # heartbeat refresh (also keyed on $PPID) matches it; a stray --pid would desync them.
  [[ "$owner" == "agent" ]] && pid="$PPID"
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
    local _dc_prereq; _dc_prereq="$(_prereq_ids_from_line "$from")"
    to="$(_serialize_item running "$prio" "$_cid" "$desc" "$_dc_prereq")"
    # #67: an AGENT claim must also hold the active-run lock so the cron guard sees all
    # three working parties uniformly. The worker path (cmd_run) already acquired the
    # active run before calling cmd_claim, so only --agent acquires here (no double-
    # acquire). We hold _with_lock, so call the lock-free _do_active_run_acquire.
    local _agent_acq=0
    if [[ "$owner" == "agent" ]]; then
      _do_active_run_acquire "$to" "$owner" "$pid" || return $?
      _agent_acq=1
    fi
    # Abort (undoing any agent active-run) if the BACKLOG transition fails, so a failed
    # write can't leave a live claim/run pointing at a never-transitioned line (#47).
    # Preserve the EXACT rc (#86): 3 = unrecoverable BACKLOG write, which the worker keys on.
    local _fl_rc; _flip_line "$from" "$to"; _fl_rc=$?
    if [[ "$_fl_rc" -ne 0 ]]; then
      [[ "$_agent_acq" -eq 1 ]] && rm -rf "$ACTIVE_RUN_DIR" 2>/dev/null || true
      return "$_fl_rc"
    fi
    # Claim file: line1=running item, line2=PID start-time, line3=owner, line4=heartbeat.
    # Old 2-line readers still work; line3/4 enable #67 agent-TTL liveness.
    local _claim_start _now; _claim_start="$(_pid_start_time "$pid")"; _now="$(date +%s)"
    if ! printf '%s\n%s\n%s\n%s\n' "$to" "$_claim_start" "$owner" "$_now" > "$STATE_DIR/$pid.claim"; then
      # Roll back the flip + agent run so we don't leave a claimless 'running' item
      # (best-effort; orphan/TTL recovery is the backstop if this also fails).
      _revert_to_waiting "$to" || true
      rm -f "$STATE_DIR/$pid.claim" 2>/dev/null || true
      [[ "$_agent_acq" -eq 1 ]] && rm -rf "$ACTIVE_RUN_DIR" 2>/dev/null || true
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
  local _rtw_prereq; _rtw_prereq="$(_prereq_ids_from_line "$raw")"
  to="$(_serialize_item waiting "$prio" "$_rid" "$desc" "$_rtw_prereq")"
  _flip_line "$raw" "$to"
}

# #65: Detect stray uncommitted changes in the main working tree after a worker dies.
# Only tracks modifications and untracked files; ignored files are explicitly out of scope.
# context_pid ($1): the dead worker's PID for correlation messages; empty for doctor mode.
# In recover mode (pid given): only prints when dirty (silent when clean — no spam on clean runs).
# In doctor mode (no pid): always prints status (dirty list or "main tree is clean").
_check_main_tree_dirty() {
  local context_pid="${1:-}" dirty="" git_rc=0
  # Silently skip when not in a git repo (test environments, non-git deputy roots).
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # Use || to prevent errexit from triggering if git status fails for another reason.
  dirty="$(git -C "$ROOT" status --porcelain -- '.' ':(exclude)BACKLOG.md' ':(exclude).deputy' 2>/dev/null)" || git_rc=$?
  if [[ "$git_rc" -ne 0 ]]; then
    printf 'deputy: git status failed (rc=%d); skipping dirty-tree check\n' "$git_rc" >&2
    return 0
  fi
  if [[ -n "$dirty" ]]; then
    if [[ -n "$context_pid" ]]; then
      printf 'deputy recover: WARNING — main tree has uncommitted changes (may be leftovers from hung worker pid %s):\n%s\n' "$context_pid" "$dirty" >&2
      _notify warn "main tree has uncommitted changes; may be leftovers from hung worker pid $context_pid" >/dev/null 2>&1 || true
    else
      printf 'deputy doctor: WARNING — main tree has uncommitted changes:\n%s\n' "$dirty"
    fi
  else
    [[ -z "$context_pid" ]] && printf 'deputy doctor: main tree is clean\n'
  fi
}

cmd_recover() {
  _do_recover() {
    # #94: restore a torn BACKLOG from a leftover .bak before any claim/orphan work.
    _recover_torn_backlog || true
    local f pid line
    # (1) Dead-claim recovery: reap any claim that is NOT live. _claim_live is #67
    # agent-TTL aware, so a fresh-heartbeat agent claim (dead PID, fresh line-4) is
    # left alone; only an expired/dead claim is reverted+removed.
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"; pid="${pid%.claim}"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      _claim_live "$f" && continue
      # Read item line from line 1 of claim file.
      line="$(sed -n '1p' "$f" 2>/dev/null || true)"
      # Revert the stale claim's line to waiting BEFORE dropping the claim file; if
      # that write fails, keep the claim file so recovery can retry rather than
      # orphaning a 'running' line with no claim record (#47).
      [[ -n "$line" ]] && { _revert_to_waiting "$line" || return 1; }
      _check_main_tree_dirty "$pid"  # #65: warn about stray leftovers from hung worker
      rm -f "$f"
    done
    # Collect item lines still held by a LIVE claim (agent-TTL aware via _claim_live),
    # CANONICALIZED so a claim's stored line still matches the current BACKLOG line after
    # a #62 order migration (or # / legacy-symbol normalization).
    local -a claimed=()
    for f in "$STATE_DIR"/*.claim; do
      [[ -e "$f" ]] || continue
      _claim_live "$f" || continue
      claimed+=("$(_canon_line "$(sed -n '1p' "$f" 2>/dev/null || true)")")
    done
    # (2) Orphan recovery: any @/~ item not held by a live claim (compare by canonical
    # identity, not raw text, so a migrated line isn't seen as orphaned and reverted).
    local raw rawc parsed state c found
    while IFS= read -r raw; do
      parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
      [[ "$state" == "running" || "$state" == "triaging" ]] || continue
      rawc="$(_canon_line "$raw")"
      found=0
      for c in "${claimed[@]:-}"; do [[ "$c" == "$rawc" ]] && { found=1; break; }; done
      [[ "$found" -eq 0 ]] && { _revert_to_waiting "$raw" || return 1; }
    done < <(_each_item)
  }
  local _rec_rc=0; _with_lock _do_recover || _rec_rc=$?
  [[ "$_rec_rc" -eq 0 ]] && _commit_queue "recover"
  return "$_rec_rc"
}

cmd_review() { cmd_watch --once "$@"; }   # 'review' is an alias for the watch overview

# #65: Manual diagnostic: check if the main working tree has uncommitted changes outside
# BACKLOG.md and .deputy. Always prints status (clean or dirty). For automated recovery
# warnings, see _check_main_tree_dirty called from cmd_recover on dead-claim detection.
cmd_doctor() {
  _check_main_tree_dirty
}

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
# Sync the mechanical "current version" markers in README.md to $1 (version-agnostic +
# idempotent — matches any x.y.z already there). Only the two machine markers are touched
# (`currently \`X\`` and the `VERSION  # X` map line); the prose version blurbs are left
# for a human/worker to curate. No-op (returns 0) if README.md is absent.
_release_sync_readme() {
  local ver="$1" f="$ROOT/README.md" tmp
  [[ -f "$f" ]] || return 0
  tmp="$f.rel.tmp.$$"
  sed -E \
    -e "s/(currently \`)[0-9][0-9.]*(\`)/\1$ver\2/g" \
    -e "s/^(VERSION[[:space:]]+#[[:space:]]*)[0-9][0-9.]*/\1$ver/" \
    "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f"; local rc=$?    # cat > f preserves inode + perms; propagate its status
  rm -f "$tmp"
  return "$rc"
}

# Build a CHANGELOG entry for $1=version. Prefers a worker-summarized entry (headless
# `claude -p`, timeout-guarded, hardness-routed model); falls back to the raw
# `release-notes` bullets when claude is unavailable / errors / times out / emits a
# malformed entry. $2 = raw release-notes bullets, $3 = git shortlog since last tag,
# $4 = "1" forces the raw (no-LLM) path. Prints the entry (starts with '## vX — DATE').
_release_changelog_entry() {
  local ver="$1" notes="$2" gitlog="$3" no_llm="$4"
  local date entry model prompt fallback
  date="$(date +%Y-%m-%d)"
  if [[ -n "$notes" ]]; then
    fallback="$(printf '## v%s — %s\n\n%s' "$ver" "$date" "$notes")"
  else
    fallback="$(printf '## v%s — %s\n\n- (no recorded backlog items since the last release)' "$ver" "$date")"
  fi
  if [[ "$no_llm" == "1" ]] || ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "$fallback"; return 0
  fi
  model="$(_worker_model_for "release changelog summary of recent commits and done items")"
  _valid_model_id "$model" || model="claude-sonnet-4-6"
  prompt="$(printf 'You are writing ONE release entry for a project CHANGELOG.md. Output ONLY GitHub-flavored markdown — no preamble, no closing remarks, no code fences. The FIRST line must be exactly:\n## v%s — %s\nThen one summary sentence, then the changes grouped under bold subheads (**Features**, **Fixes**, **Docs** — include only those that apply) with concise one-line bullets. Merge related commits; drop noise (merge commits, "wip", release/version chores). Use ONLY the facts below; invent nothing.\n\n=== backlog items completed since last release ===\n%s\n\n=== git commits since last release ===\n%s\n' \
    "$ver" "$date" "${notes:-(none recorded)}" "${gitlog:-(none)}")"
  # Pass the prompt as an argument and redirect stdin from /dev/null so `claude -p` never
  # blocks waiting for additional stdin; timeout bounds a hung/slow worker.
  entry="$(timeout 180 claude -p "$prompt" --model "$model" </dev/null 2>/dev/null)" || entry=""
  if [[ "$entry" == "## v$ver "* || "$entry" == "## v$ver—"* ]]; then
    printf '%s\n' "$entry"
  else
    printf '%s\n' "$fallback"   # unavailable / timeout / malformed → raw bullets
  fi
}

# Prepend $2 (a complete entry) immediately above the most-recent '## ' heading in
# CHANGELOG.md (creating the file with a '# Changelog' title if absent). Returns 3 without
# writing if an entry for v$1 is already present (re-run safety).
_release_prepend_changelog() {
  local ver="$1" entry="$2" f="$ROOT/CHANGELOG.md" tmp vre
  vre="${ver//./\\.}"
  [[ -f "$f" ]] && grep -qE "^## v${vre}( |—|\$)" "$f" && return 3
  tmp="$f.rel.tmp.$$"
  if [[ -f "$f" ]]; then
    # Insert before the first existing '## ' entry (where a new release belongs); if none
    # exists yet, append at the end.
    awk -v e="$entry" '
      !ins && /^## / { print e "\n"; ins=1 }
      { print }
      END { if (!ins) print "\n" e }
    ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '# Changelog\n\n%s\n' "$entry" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  cat "$tmp" > "$f"; local rc=$?   # cat > f preserves inode + perms; propagate its status
  rm -f "$tmp"
  return "$rc"
}

# One-command release orchestrator (project rule: VERSION + CHANGELOG + BACKLOG delimiter
# + README + commit + annotated tag move in lockstep). Flags:
#   --push          also push the branch + tag to origin (default: local only, print cmd)
#   --no-llm        skip the worker-summarized CHANGELOG; use raw release-notes bullets
#   --marker-only   legacy behavior: ONLY insert the BACKLOG delimiter (used by tests)
# Version defaults to ./VERSION; env DEPUTY_RELEASE_NO_LLM=1 also forces --no-llm.
cmd_release() {
  local push=0 no_llm=0 marker_only=0 ver="" a
  for a in "$@"; do
    case "$a" in
      --push)        push=1 ;;
      --no-llm)      no_llm=1 ;;
      --marker-only) marker_only=1 ;;
      --)            ;;
      -*)            printf 'deputy: release: unknown flag %s\n' "$a" >&2; return 2 ;;
      *)             if [[ -z "$ver" ]]; then ver="$a"
                     else printf 'deputy: release: unexpected argument %s\n' "$a" >&2; return 2; fi ;;
    esac
  done
  [[ "${DEPUTY_RELEASE_NO_LLM:-}" == "1" ]] && no_llm=1
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

  # ── --marker-only: the original behavior (delimiter insert + commit only) ──
  if [[ "$marker_only" -eq 1 ]]; then
    local rrc=0; _with_lock _do_release || rrc=$?
    if [[ "$rrc" -eq 3 ]]; then
      printf 'deputy: release marker already present: %s\n' "$delim"; return 0
    elif [[ "$rrc" -ne 0 ]]; then
      printf 'deputy: release failed (exit %s)\n' "$rrc" >&2; return 1
    fi
    _commit_queue "release v$ver"    # commit AFTER the lock is released
    printf 'deputy: release marker added: %s\n' "$delim"
    return 0
  fi

  # ── FULL RELEASE ──
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'deputy: release: %s is not a git repository\n' "$ROOT" >&2; return 1; }
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1; then
    printf 'deputy: release: tag v%s already exists — bump the version or delete the tag\n' "$ver" >&2
    return 1
  fi
  local branch; branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # Preflight: VERSION/CHANGELOG.md/README.md must be clean (no staged or unstaged edits)
  # before we touch them, so the release commit cannot sweep in unrelated pending edits to
  # these files. BACKLOG.md is intentionally excluded — it is deputy-owned and routinely
  # dirty (the live queue) at release time, and its worktree state is what we want to commit.
  if ! git -C "$ROOT" diff --quiet -- VERSION CHANGELOG.md README.md 2>/dev/null \
     || ! git -C "$ROOT" diff --cached --quiet -- VERSION CHANGELOG.md README.md 2>/dev/null; then
    printf 'deputy: release: VERSION/CHANGELOG.md/README.md have uncommitted changes — commit or stash them first (release owns these files)\n' >&2
    return 1
  fi

  # 1. Capture change context BEFORE inserting the new delimiter. release-notes reads
  #    "done since the last delimiter"; the git range is since the last v* tag.
  local notes gitlog prev_tag
  notes="$(cmd_release_notes 2>/dev/null)"
  [[ "$notes" == "No unreleased items." ]] && notes=""
  prev_tag="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  gitlog="$(git -C "$ROOT" log --no-merges --pretty='- %s' ${prev_tag:+"$prev_tag..HEAD"} 2>/dev/null)"

  # 2. Generate + prepend the CHANGELOG entry (worker-summarized, raw fallback).
  #    Return 3 = a 'v$ver' entry is already present. The tag-collision guard above already
  #    blocked a genuine re-release, so reaching here means a PARTIAL/resumed release whose
  #    CHANGELOG landed but tag did not — leave the entry as-is and finish the release.
  local entry; entry="$(_release_changelog_entry "$ver" "$notes" "$gitlog" "$no_llm")"
  _release_prepend_changelog "$ver" "$entry"; local crc=$?
  if [[ "$crc" -eq 3 ]]; then
    printf 'deputy: release: CHANGELOG already has a v%s entry — reusing it (completing a partial release)\n' "$ver" >&2
  elif [[ "$crc" -ne 0 ]]; then
    printf 'deputy: release: failed to update CHANGELOG.md (exit %s) — aborting before any VERSION bump or tag\n' "$crc" >&2
    return 1
  fi

  # 3. Bump VERSION.
  printf '%s\n' "$ver" > "$ROOT/VERSION"

  # 4. Insert the BACKLOG delimiter (idempotent; writes BACKLOG.md in the worktree — the
  #    git commit is folded into the single release commit in step 6 below).
  local rrc=0; _with_lock _do_release || rrc=$?
  if [[ "$rrc" -ne 0 && "$rrc" -ne 3 ]]; then
    printf 'deputy: release: BACKLOG delimiter insert failed (exit %s) — nothing committed or tagged; revert the partial edits with `git checkout -- VERSION CHANGELOG.md README.md BACKLOG.md`\n' "$rrc" >&2
    return 1
  fi

  # 5. Sync README version references (cosmetic — warn, don't abort, on failure).
  _release_sync_readme "$ver" || printf 'deputy: release: warning — README version sync failed (continuing)\n' >&2

  # 6. Commit VERSION + CHANGELOG + README + BACKLOG in ONE release commit (explicit paths —
  #    never sweep other dirty files), then create the annotated tag on that commit. Folding
  #    BACKLOG.md in here (instead of a separate best-effort _commit_queue) guarantees the tag
  #    always captures the delimiter — the version bump and the delimiter can't diverge.
  #    Reset the index for these paths first so any PRE-staged content can't ride along — the
  #    commit then reflects exactly the release-generated worktree state of these files.
  #    README.md is optional, so build the path list from files that actually exist (a
  #    `git add -- <missing>` would abort and stage nothing).
  local -a rel_paths=(VERSION CHANGELOG.md BACKLOG.md)
  [[ -f "$ROOT/README.md" ]] && rel_paths+=(README.md)
  git -C "$ROOT" reset -q -- "${rel_paths[@]}" >/dev/null 2>&1
  git -C "$ROOT" add  --   "${rel_paths[@]}" >/dev/null 2>&1
  if git -C "$ROOT" diff --cached --quiet -- "${rel_paths[@]}"; then
    # Nothing to commit. Only safe to tag if HEAD is ALREADY this release (a resumed run
    # whose commit landed but whose tag did not); otherwise we'd tag an unrelated commit.
    local head_ver; head_ver="$(git -C "$ROOT" show HEAD:VERSION 2>/dev/null | tr -d '[:space:]')"
    if [[ "$head_ver" != "$ver" ]]; then
      printf 'deputy: release: nothing to commit and HEAD is not v%s (HEAD VERSION=%s) — refusing to tag an unrelated commit\n' "$ver" "${head_ver:-none}" >&2
      return 1
    fi
    printf 'deputy: release: no file changes — HEAD already is v%s; tagging it\n' "$ver" >&2
  else
    git -C "$ROOT" commit -q -m "release: v$ver" -- "${rel_paths[@]}" || {
      printf 'deputy: release: commit failed — nothing tagged; inspect with `git status` and re-run or `git checkout -- VERSION CHANGELOG.md README.md BACKLOG.md`\n' >&2
      return 1; }
  fi
  git -C "$ROOT" tag -a "v$ver" -m "v$ver" || {
    printf 'deputy: release: tag v%s failed — the release commit landed; retag with `git tag -a v%s -m v%s`\n' "$ver" "$ver" "$ver" >&2
    return 1; }

  # 7. Push is opt-in — deputy never publishes on its own. Push the branch and EXACTLY this
  #    tag (not --follow-tags, which would also publish unrelated local annotated tags).
  if [[ "$push" -eq 1 ]]; then
    if git -C "$ROOT" push origin "$branch" "v$ver"; then
      printf 'deputy: released v%s and pushed origin/%s + tag v%s.\n' "$ver" "$branch" "$ver"
    else
      printf 'deputy: released v%s locally, but push FAILED — retry: git push origin %s v%s\n' "$ver" "$branch" "$ver" >&2
      return 1
    fi
  else
    printf 'deputy: released v%s locally — VERSION + CHANGELOG + BACKLOG delimiter + tag v%s.\n' "$ver" "$ver"
    printf '        push when ready:  git push origin %s v%s\n' "$branch" "$ver"
  fi
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
  local f; f="$(_trail_path reviews "$slug")"   # #70: .deputy/reviews/<slug>.md
  # Seed a header the first time so the file is self-describing.
  [[ -s "$f" ]] || printf '# xReview trail — %s\n' "$slug" >> "$f"
  printf '\n' >> "$f"
  cat >> "$f"
  printf '\n' >> "$f"
}

usage() {
  local full="${1:-}"
  cat <<'COMMANDS'
usage: deputy <command> [args]

  Task IDs: pass a BARE integer (e.g. 42) — an unquoted '#42' is a shell comment, so it
  reaches deputy as no args. Quote it as '#42' if you prefer the hash form. This applies
  everywhere an <id> is accepted: list / slug / pickup / run / set / clean.

commands:
  add "<text>" [-ui|-u|-i]        add a waiting item and run it immediately if idle
                                  (-ui=P0 -u=P1 -i=P2; --p0/--p1/--p2/--p3/--p4 also accepted;
                                  no flag → default priority P3 assigned at numbering;
                                  use -- before a description that starts with "-";
                                  set DEPUTY_NO_AUTORUN=1 to enqueue without running)
                                  Acceptance (#113): --observe/--actual/--expect/--where
                                  (+ optional --match <regex>)
                                  record the reported symptom; when the text reads like a
                                  bug and you are at a terminal, deputy asks for those four
                                  instead. --no-accept skips it (chores); DEPUTY_NO_GRILL=1
                                  or config accept_grill=0 disables the prompt everywhere
  accept <id|slug>                print a task's acceptance record — the reported symptom
    [--observe <cmd>]             frozen in the reporter's words. With any flag, create or
    [--actual <text>]             update it instead (use this to backfill an item added
    [--expect <text>]             before the record existed). observe is the command deputy
    [--where <text>]              runs to SEE the symptom; it is what 'verify' checks.
    [--match <regex>]             --match is OPTIONAL and machine-checked: red/bite score any
                                  nonzero exit as "symptom present", so without it a blank
                                  column that has become a thrown exception still counts as
                                  the same bug. Set it when that difference matters
  verify <id|slug> --<phase>      prove the symptom moved — not just that code landed:
                                  --red    before the fix: observe MUST FAIL (symptom is
                                           real + the check captures it). Passing here
                                           means do NOT proceed — the check is wrong
                                  --green  after the fix: observe MUST PASS
                                  --bite   revert this branch's own commits in a scratch
                                           worktree; observe MUST FAIL again. Catches a
                                           test written to fit the diff rather than the bug
                                  --smoke  run config smoke_cmd against the real
                                           environment (green unit tests are not evidence
                                           when the bug only exists against live data)
                                  --status print the recorded verdicts
                                  exit 0 = pass (or a skipped gate), 1 = the gate FAILED,
                                  2 = cannot run (no record/observe/smoke_cmd, bad usage),
                                  3 = INCONCLUSIVE (timed out, command not found, or no
                                  clean reverted tree) — no evidence either way, which is
                                  never the same as a pass
                                  --red is SKIPPED (exit 0) once the item has committed
                                  work: on a resumed run the pre-fix state is already gone
  slug <id>                       print a task's canonical, frozen branch slug
                                  (<id>-<hash>-<desc>, fixed at add-time from the immutable
                                  user description). The orchestrator uses this so every
                                  resume/rerun of a task reuses the SAME branch/worktree
  list [<state>] [--porcelain]    print items in BACKLOG.md format (e.g. '@[#1][P0] desc');
                                  optional state filter — bare '<state>' (e.g. 'deputy list
                                  waiting'), '--state <state>', or '--<state>' shorthand;
                                  no arg lists all.
                                  --porcelain: emit stable machine-readable output instead —
                                  one 'state|prio|id|desc' line per item (desc is the raw
                                  remainder after the 3rd pipe and may itself contain '|';
                                  prio and id are empty strings when unset); composes with
                                  all state filters; use 'cut -d"|" -f4-' to extract desc
  status                          counts by state
  test [--changed] [<name>...]    run the test suite (config test_cmd, else tests/run.sh). With
                                  --changed, run ONLY the tests affected by the working-tree diff
                                  (bin/deputy.sh changed functions → tests/test-map + cmd_<X>→
                                  test_<X> convention); anything not confidently mapped runs the
                                  FULL suite (fail-safe, never a silent skip). <name>... runs
                                  just those test files (e.g. 'deputy test list pickup')
  pickup <id>                     bring up ONE attention task and ACT on it: ready-to-merge →
                                  merge into the default branch (→ done); proposed → approve
                                  (→ waiting); needs-input → point to /deputy; pending-merge →
                                  merge it now instead of waiting for the next tick; failed/
                                  cancelled/deferred/paused → requeue (→ waiting). Local/safe (never
                                  pushes). See candidates with 'deputy list <state>'
  watch [--once] [--apply]        the "what needs me" command: prints the queue OVERVIEW
                                  (learnings, untagged items, reprioritization review, duplicate
                                  candidates, status) then runs as a passive monitor — live-tails
                                  a running worker and, on quiescence (runnable→0 with a surfaced/
                                  failed/deferred item), beeps 3× + prints the attention digest
                                  (each item's next action → 'deputy pickup <id>'). --once:
                                  overview + one poll then exit. --apply: overview + write
                                  .deputy/learnings.md then exit. Ctrl-C exits. (aliases: tail,
                                  review; replaces the former 'reflect')
  watch <id>  /  progress <id>    PASSIVE, READ-ONLY per-task progress view: from the
                                  waypoint ledger + run log print step-progress %, the
                                  current step, a 'done so far' digest, an ETA band, and
                                  a run-log tail. One-shot; never signals/follows/touches
                                  the running worker (safe on a live, paused, or dead run)
  run [<id>] [--once] [--headless] work the backlog: claim the top item, run the orchestrator
                                  (interactive/TTY runs stream output live; --headless or
                                  headed=0 config forces the buffered/cron behavior)
                                  if an <id> is given, run that specific item bypassing
                                  priority order (targeted, one item only). <id> is an
                                  integer or a hand-written sub-id like 145.2 (see below)
  set <id|"<exact line>"> <state|pN>
                                  change an item's state or priority — target by <id> or
                                  exact-line match. Value shape decides: a state word sets
                                  state, 'p0'..'p4' sets priority. e.g. `deputy set 50 done`,
                                  `deputy set 50 p0`. Explicit `set state 50 done` /
                                  `set prio 50 p0` forms also accepted.
  cron ensure|remove|status|set <N>
                                  manage the safety-net schedule (legacy --ensure/--remove
                                  also accepted). 'cron set <N>' changes the heartbeat interval
                                  to N minutes (1–59): updates .deputy/config and re-applies
                                  the crontab if cron is already enabled.
                                  NOTE: 'cron reschedule "<text>"' exists but is
                                  orchestrator-internal (quota-failover) — not for manual use
  clean [<id>|<state>] [--dry-run]
                                  remove items matching the filter:
                                    <id>           clean one item by id
                                    <state>        remove all items of <state> (e.g. 'clean done';
                                                   '--state <s>' also accepted; default: waiting)
                                  cleanable states: waiting, done, failed, cancelled, duplicate, deferred
                                  refuses running, triaging, surfaced, paused (active/checkpointed/awaiting)
  config [<key> [value]]          read or set a .deputy/config key. No args / one arg = read;
                                  'config <key> <value>' upserts it (atomic; one line per key).
                                  'config autonomy on|off' is a shorthand that sets BOTH
                                  autonomy knobs at once (auto_merge + self_review_fallback).
                                  e.g. 'deputy config auto_merge 1', 'deputy config autonomy on'
  release [version] [--push]      cut a release (version defaults to ./VERSION): bump
                                  VERSION, prepend a worker-summarized CHANGELOG entry
                                  (--no-llm for raw release-notes bullets), insert the
                                  BACKLOG delimiter, sync README, commit + annotated tag.
                                  Local only unless --push (deputy never auto-publishes).
                                  --marker-only inserts just the BACKLOG delimiter.
  release-notes                   print Done items above the most-recent release delimiter
                                  as a CHANGELOG-ready bullet list (done-since-last-release);
                                  if no delimiter exists, prints all Done items
  version                         print the installed deputy version (also --version, -V)
  help [--full]                   show this message (--full: include config key documentation)

  Item ids: auto-assigned as plain integers (#7). You may HAND-WRITE a sub-id with a
  '.<n>' suffix (#145.2) to mark a sub-item of #145. #145.2 is a full, independent item
  id (run/set/target it like any other) — only its RELATIONSHIP to #145 is a human label;
  the two share no scheduling/merge. Accepted anywhere an <id> is (run/set/list/clean/
  pickup/progress); its integer prefix still counts in auto-allocation.
COMMANDS
  if [[ "$full" == "--full" ]]; then
    cat <<'CONFIG'
config keys (.deputy/config)  — set with 'deputy config <key> <value>':
  # autonomy (a spawned headless worker reads ONLY .deputy/config — NOT the interactive
  #  Claude terminal's auto-mode, which is ephemeral + invisible to workers; wire intent here):
  auto_merge=1                    allow a spawned (headless) worker's branch to be merged to the default branch (the unsandboxed runner does the merge); default 0 = surface the branch for human review
  self_review_fallback=1          when xReview has no peer reviewer (both Codex+Gemini down), self-review with a warning and proceed; default 0 = surface the item for the user instead (legacy name 'auto_mode' is still read)
  # 'deputy config autonomy on|off' sets BOTH of the above at once. NOTE: push is NEVER
  #  automatic — auto_merge governs only the LOCAL merge.
  # scheduling / other:
  max_items=N                     items started per run cycle (default 1; min 1). MIGRATION: 0 no longer means unlimited — it clamps to 1; set an explicit N for a multi-item drain
  heartbeat_mins=N                cron heartbeat interval in minutes (default 10; 1–59); use 'deputy cron set N' to change it live
  human_backoff=1                 back off when an interactive Claude session is busy/recent in this repo (default 1; set 0 to disable)
  human_idle_grace_mins=N         allow cron to run when Claude has been idle this many minutes (default 5)
  waiting_backoff_strikes=N       consecutive 'waiting' heartbeat ticks required before cron proceeds (default 3)
  startup_fail_strikes=N          consecutive spawns that die before any waypoint progress before the startup-crash circuit-breaker SURFACES the item (default 3)
  orphan_warn_mins=N              warn (never kill) about a bash orphan running > this many minutes under an in-repo Claude session (default 30)
  watchdog_mins=N                 hard-cap a headless worker that makes NO waypoint progress for N min: surface the item + kill the worker (a hung/looping worker can't burn tokens or hold the slot). Default 45; set 0 to disable
  auto_merge=1                    allow a spawned (headless) worker to git-merge its branch to the default branch; default 0 = the guardrail blocks the merge and the worker must surface the branch for human review
  delete_merged_branch=1          after a successful merge, delete the local deputy/<slug> branch (uses 'git branch -d', merged-only safe delete, NEVER -D/-f); default: auto-ON when auto_merge=1 (full automation implies cleanup), OFF otherwise; set =0 to keep branches even with auto_merge=1
  notify_on_spawn=0               silence the notification + cron.log '===SPAWN===' line emitted when the heartbeat autonomously spawns a worker; default 1 = announce every autonomous pickup (never silent)
  sandbox=0                       disable the bwrap read-only sandbox around the headless worker (default 1 = repo code is OS-read-only to the worker, only .deputy/+BACKLOG.md+worktree writable); 0 falls back to cwd-pinning only
  worker_model=<id>               headless-worker model for a SIMPLE item (default claude-sonnet-4-6). Worker model is routed by a cheap pre-spawn HARDNESS heuristic on the description
  worker_model_moderate=<id>      model for a MODERATE item (new command/flag/wiring, or a medium description); falls through to worker_model if unset. e.g. claude-fable-5
  worker_model_complex=<id>       model for a COMPLEX/hard item (refactor/redesign/security/scope/grill keywords, or a long description); falls through to worker_model_moderate → worker_model. e.g. claude-opus-4-8
  worker_fallback_model=<id>      if set, passed as claude --fallback-model so the worker auto-falls-back when the chosen model is unavailable/rate-limited
  notify=desktop,push,email       channels for item-surfaced/finished notifications
  notify_push_url=<url>           ntfy.sh-compatible push URL (required for push)
  notify_email=<address>          recipient address (required for email)
  smoke_cmd=<command>             #113: end-to-end check run against the REAL environment/data by 'deputy verify --smoke'. When set, a passing smoke run is required before 'deputy done' (waive with 'done --no-verify'). Unset = no smoke gate. Exists because green unit tests are not evidence for a bug that only reproduces against live data
  accept_grill=0                  #113: disable the interactive acceptance prompt on 'deputy add' (default on for bug-shaped descriptions at a TTY; DEPUTY_NO_GRILL=1 does the same per-invocation). The four fields can still be passed as flags
  verify_timeout_secs=<n>         #113: per-run cap for a 'deputy verify' observe/smoke command (default 300), so a hung check can never wedge a headless worker
CONFIG
  else
    printf 'Run "deputy help --full" for config key documentation.\n\n'
  fi
  cat <<'FOOTER'
states: waiting triaging running surfaced done failed cancelled duplicate paused deferred pending-merge
symbols: (none)=waiting ~=triaging @=running ?=surfaced +=done !=failed %=cancelled ==duplicate ^=paused ;=deferred &=pending-merge  (legacy #=done >=deferred still read and auto-migrated)
FOOTER
}

# #72: focused per-command help. Slices the command's block out of usage() — the SINGLE
# source of truth, so `deputy <cmd> --help` can never drift from `deputy help`. A block
# is the `  <cmd> ` line plus its indented continuation lines, up to the next command,
# section header, or blank. Commands without a documented block (internal/plumbing verbs)
# fall back to the full usage.
_cmd_help() {
  local cmd="$1" full="${2:-}" block
  # public aliases resolve to their documented command's block (review/reflect/tail → watch)
  case "$cmd" in review|reflect|tail) cmd=watch ;; esac
  block="$(usage | awk -v c="$cmd" '
    # literal prefix match ("  <cmd> ") — never interpret cmd as a regex, so a
    # regex-shaped unknown command falls back to usage instead of matching a block.
    BEGIN { p = "  " c " "; pl = length(p) }
    substr($0, 1, pl) == p && !grab { grab=1; print; next }
    grab && /^  [^ ]/        { exit }   # next command block (exactly 2-space indent)
    grab && /^[^ ]/          { exit }   # next section header (column 0)
    grab && /^[[:space:]]*$/ { exit }   # blank line → end of the commands section
    grab                     { print }
  ')"
  if [[ -n "$block" ]]; then
    printf '%s\n' "$block"
  else
    usage "$full"
  fi
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
  # #88: bare subcommands (ensure|remove|status) are the user-facing verbs; the legacy
  # '--ensure'/'--remove' flag forms remain as back-compat aliases. 'reschedule' (bare or
  # '--reschedule') is orchestrator-INTERNAL — the quota-failover verb the worker calls;
  # it stays functional but is NOT advertised in `deputy help` (like claim/pick/spine verbs).
  case "${1:-}" in
    ensure|--ensure)
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
    remove|--remove)     rm -f "$STATE_DIR/cron.enabled" 2>/dev/null || true; _set_cron "" ;;
    set)
      local _n="${2:-}"
      if [[ -n "${3:-}" ]]; then
        printf 'deputy: cron set takes exactly one argument (got extra: %s)\n' "${3}" >&2; return 2
      fi
      if ! [[ "$_n" =~ ^[0-9]+$ ]] || ! (( 10#$_n >= 1 && 10#$_n <= 59 )); then
        printf 'deputy: cron set requires an integer between 1 and 59 (got: %s)\n' "${_n:-<empty>}" >&2
        return 2
      fi
      local cfg="$STATE_DIR/config" _tmp _gs=0 _was_enabled=0
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      [[ -f "$cfg" ]] || touch "$cfg"
      _tmp="$(mktemp "$STATE_DIR/.config.tmp.XXXXXX")"
      grep -v '^heartbeat_mins=' "$cfg" > "$_tmp" || _gs=$?
      if [[ "$_gs" -gt 1 ]]; then
        rm -f "$_tmp"; printf 'deputy: cron set: config read error\n' >&2; return 1
      fi
      printf 'heartbeat_mins=%s\n' "$_n" >> "$_tmp"
      if _cron_enabled; then _was_enabled=1; fi
      if [[ "$_was_enabled" -eq 1 ]]; then
        if ! _set_cron "*/$_n * * * *"; then
          rm -f "$_tmp"; printf 'deputy: cron set: crontab update failed\n' >&2; return 1
        fi
      fi
      mv "$_tmp" "$cfg"
      if [[ "$_was_enabled" -eq 1 ]]; then
        printf 'heartbeat updated to %s min and crontab rescheduled\n' "$_n"
      else
        printf 'heartbeat_mins set to %s (cron not enabled; run "deputy cron ensure" to activate)\n' "$_n"
      fi
      ;;
    reschedule|--reschedule) local h; h="$(_parse_reset_hour "${2:-}")"
                  if [[ -n "$h" ]]; then _set_cron "0 $h * * *"
                  else _set_cron "0 */2 * * *"; fi ;;
    status)
      local root marker cron_lines cron_line schedule enabled last_run
      root="$(resolve_root)"
      marker="# deputy[$root]"
      if _cron_enabled; then enabled="yes"; else enabled="no"; fi
      cron_lines="$(_crontab -l 2>/dev/null || true)"
      cron_line="$(printf '%s\n' "$cron_lines" | grep -F "$marker" | head -1 || true)"
      if [[ -n "$cron_line" ]]; then
        schedule="$(printf '%s\n' "$cron_line" | awk '{print $1,$2,$3,$4,$5}')"
      else
        schedule="(not scheduled)"
      fi
      if [[ -f "$STATE_DIR/cron.log" ]]; then
        local mtime
        mtime="$(stat -c %Y "$STATE_DIR/cron.log" 2>/dev/null \
                 || stat -f %m "$STATE_DIR/cron.log" 2>/dev/null || true)"
        if [[ -n "$mtime" ]]; then
          last_run="$(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null \
                      || date -r "$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null \
                      || echo '(unknown)')"
        else
          last_run="(unknown)"
        fi
      else
        last_run="(never)"
      fi
      printf 'enabled:  %s\nschedule: %s\nlast run: %s\n' "$enabled" "$schedule" "$last_run"
      ;;
    *) printf 'deputy: cron needs ensure|remove|status|set (legacy --ensure/--remove also accepted)\n' >&2; return 2 ;;
  esac
}

# Read a single key from .deputy/config (KEY=VALUE). Echoes the value or empty.
_config_get() {
  # #76: LAST-wins on duplicate keys (later lines override earlier — standard config
  # semantics). This makes an appended override win even when an earlier line (e.g. a key
  # materialized by the template auto-seed) already set the key, instead of silently
  # returning the stale first value.
  local key="$1" cfg="$STATE_DIR/config" line k v val="" seen=0
  [[ -f "$cfg" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    if [[ "$k" == "$key" ]]; then val="$v"; seen=1; fi
  done < "$cfg"
  (( seen )) && { printf '%s\n' "$val"; return 0; }
  # #90 back-compat: 'auto_mode' was renamed to 'self_review_fallback'. If the new key is
  # unset, transparently fall back to the legacy key so existing .deputy/config keeps working.
  [[ "$key" == "self_review_fallback" ]] && _config_get auto_mode
  return 0
}

# True (0) if the given key is PRESENT in .deputy/config (any value, incl. empty 'key=').
# Distinguishes an explicit empty '(disable)' from an absent key (#90 empty=disable semantics).
_config_has() {
  local key="$1" cfg="$STATE_DIR/config"
  [[ -f "$cfg" ]] || return 1
  grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$cfg"
}

# #103: tri-state branch-delete decision. Returns 0 (delete) when:
#   delete_merged_branch=1           → always delete (explicit opt-in)
#   delete_merged_branch present, ≠1 → never delete  (explicit opt-out — '0' OR empty '(disable)',
#                                       #90 semantics; wins over auto_merge)
#   delete_merged_branch ABSENT
#     + auto_merge=1                 → delete (full automation implies cleanup)
#     + auto_merge!=1                → preserve (default, no change for non-auto repos)
_should_delete_merged_branch() {
  [[ "$(_config_get delete_merged_branch)" == "1" ]] && return 0
  _config_has delete_merged_branch && return 1     # present but not 1 (0 or empty) → preserve
  [[ "$(_config_get auto_merge)" == "1" ]] && return 0   # absent + auto_merge=1 → delete
  return 1
}

# Write a single key to .deputy/config as an ATOMIC UPSERT (#90): drop any existing 'key='
# lines (tolerating spaces around '=', which _config_get also trims), append 'key=value',
# temp+rename. One line per key — the file never accumulates duplicates. An empty value writes
# 'key=' (an explicit disable that overrides a prior value).
_config_set() {
  local key="$1" val="${2:-}" cfg="$STATE_DIR/config" tmp _grc=0
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'deputy: config: invalid key: %s\n' "$key" >&2; return 2; }
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  tmp="$(mktemp "$STATE_DIR/.config.tmp.XXXXXX")" || return 1
  if [[ -f "$cfg" ]]; then
    # '|| _grc=$?' keeps set -e from tripping on grep's no-match (rc 1); rc>1 is a real read
    # error — don't replace a possibly-good config with a truncated one.
    grep -v "^[[:space:]]*${key}[[:space:]]*=" "$cfg" > "$tmp" || _grc=$?
    [[ "$_grc" -gt 1 ]] && { rm -f "$tmp"; printf 'deputy: config: cannot read %s\n' "$cfg" >&2; return 1; }
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# 'deputy config'            — list the current (non-comment) config lines
# 'deputy config <key>'      — read one key
# 'deputy config <key> <v>'  — upsert-write ('autonomy on|off' sets BOTH autonomy knobs at once)
cmd_config() {
  if [[ $# -eq 0 ]]; then
    [[ -f "$STATE_DIR/config" ]] && grep -vE '^[[:space:]]*(#|$)' "$STATE_DIR/config" || true
    return 0
  fi
  local key="$1"
  [[ $# -eq 1 ]] && { _config_get "$key"; return 0; }
  [[ $# -gt 2 ]] && { printf 'deputy: config: too many arguments (expected: config <key> [value])\n' >&2; return 2; }
  local val="$2"
  if [[ "$key" == "autonomy" ]]; then
    local v
    case "$val" in on|1|true|yes) v=1 ;; off|0|false|no) v=0 ;;
      *) printf 'deputy: config autonomy expects on|off (got: %s)\n' "$val" >&2; return 2 ;;
    esac
    _config_set auto_merge "$v" && _config_set self_review_fallback "$v" || return 1
    printf 'autonomy %s → auto_merge=%s, self_review_fallback=%s\n' "$val" "$v" "$v"
    return 0
  fi
  _config_set "$key" "$val" || return $?   # propagate rc (e.g. 2 for an invalid key)
  printf '%s=%s\n' "$key" "$val"
}

# True (0) if any path (newline-separated, from $1) matches a glob in
# .deputy/protected. Deterministic; used as the pre-commit gate.
_protected_violation() {
  local input="$1" path glob src
  # #76: layer the per-project .deputy/protected OVER the release template defaults
  # ($SRC_DIR/templates/protected), checking BOTH at read time. New default protected
  # globs shipped in a deputy upgrade therefore apply to every existing project WITHOUT
  # re-running init, and a project with no .deputy/protected still gets the safe baseline.
  local -a srcs=( "$STATE_DIR/protected" "$SRC_DIR/templates/protected" )
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    for src in "${srcs[@]}"; do
      [[ -f "$src" ]] || continue
      while IFS= read -r glob || [[ -n "$glob" ]]; do
        [[ -n "$glob" && "$glob" != \#* ]] || continue
        case "$path" in $glob) return 0 ;; esac
      done < "$src"
    done
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
    # Capture branch name before removing (needed for optional post-merge cleanup).
    local branch=""
    [[ -e "$wt" ]] && branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
    # Remove the worktree; track success so branch cleanup is never attempted on failure.
    local removed=0
    if [[ -e "$wt" ]]; then
      git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null && removed=1 || true
    fi
    git -C "$ROOT" worktree prune 2>/dev/null || true
    # Opt-in cleanup: delete the merged deputy/<slug> branch when configured.
    # Safety: uses 'git branch -d' (merged-only, never -D/-f) — fails silently when
    # the branch is NOT merged (surface/abort/conflict paths). Require $ROOT to be on
    # the DEFAULT branch (not merely "not a deputy/* branch"): 'git branch -d' tests
    # merged-into-HEAD, so deleting must be gated on HEAD being the default branch —
    # otherwise a manual wt-remove from another feature branch where deputy/<slug>
    # happens to be merged could delete a branch never merged into the default one.
    if _should_delete_merged_branch && [[ "$removed" == "1" && "$branch" == deputy/* ]]; then
      local cur_br def_br
      cur_br="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      def_br="$(_default_branch)"
      # Strict containment: 'git branch -d' also accepts "merged into upstream", so a
      # tracked branch could slip through. Require the branch to be an ancestor of HEAD
      # (i.e. actually contained in the default branch) before deleting.
      if [[ -n "$def_br" && "$cur_br" == "$def_br" ]] \
         && git -C "$ROOT" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
        git -C "$ROOT" branch -d "$branch" 2>/dev/null \
          && printf 'deputy: deleted merged branch %s\n' "$branch" >&2 \
          || true
      fi
    fi
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
      _surf_qf="$(_trail_path questions "$_surf_slug")"   # #70: .deputy/questions/<slug>.md
      _surf_set_rc=0
      cmd_set "$_stale_item" surfaced || _surf_set_rc=$?
      if [[ "$_surf_set_rc" -eq 0 ]]; then
        local _surf_line_surfaced _surf_prereq
        _surf_prereq="$(_prereq_ids_from_line "$_stale_item")"
        _surf_line_surfaced="$(_serialize_item surfaced "$_surf_prio" "$_surf_id" "$_surf_desc" "$_surf_prereq")"
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

# A syntactically-valid Claude model id (e.g. claude-sonnet-4-6). Guards against a typo or a
# flag-like config value reaching 'claude --model'. Does NOT verify the model actually exists.
_valid_model_id() { [[ "$1" =~ ^claude-[a-z0-9._-]+$ ]]; }

# Classify an item's HARDNESS (simple|moderate|complex) from a cheap PRE-SPAWN heuristic on its
# description — length + keyword signals. The real triage happens INSIDE the worker, so this is
# only a quota-routing hint (a wrong guess just picks a different model's quota; all can do the
# work). Tunable: adjust the thresholds/keywords here.
_item_hardness() {
  local desc="$1" n; n="${#desc}"
  # complex/hard: big scope or design/refactor/systemic keywords
  if [[ "$n" -gt 400 ]] || printf '%s' "$desc" \
       | grep -qiE 're-?factor|re-?design|architect|migrat|concurren|\brace\b|security|guardrail|\bgrill\b|non-trivial|trade-?off|\bscope\b'; then
    printf 'complex'; return 0
  fi
  # moderate: a real feature — new command/flag/option/wiring — or a medium description
  if [[ "$n" -gt 150 ]] || printf '%s' "$desc" \
       | grep -qiE 'add .*(command|sub-?command|flag|option|config|verb)|\bwire\b|integrat|consolidat|\bunify\b|new (command|verb|flag)'; then
    printf 'moderate'; return 0
  fi
  printf 'simple'
}

# Choose the worker model for an item (echoed), routed by _item_hardness:
#   complex  → worker_model_complex  (fallthrough: → worker_model_moderate → worker_model)
#   moderate → worker_model_moderate (fallthrough: → worker_model)
#   simple   → worker_model          (default claude-sonnet-4-6)
# Any tier left unset falls through to the next lighter tier, so configuring only some is fine.
_worker_model_for() {
  local item="$1" desc base mod cx
  base="$(_config_get worker_model)"; base="${base:-claude-sonnet-4-6}"
  mod="$(_config_get worker_model_moderate)"
  cx="$(_config_get worker_model_complex)"
  desc="$(_parse_item "$item")"; desc="${desc#*|}"; desc="${desc#*|}"; desc="${desc#*|}"
  local model
  case "$(_item_hardness "$desc")" in
    complex)  model="${cx:-${mod:-$base}}" ;;
    moderate) model="${mod:-$base}" ;;
    *)        model="$base" ;;
  esac
  # Guard against a typo/flag-like config value reaching 'claude --model'.
  if ! _valid_model_id "$model"; then
    printf 'deputy: worker model %q is not a valid model id — using claude-sonnet-4-6\n' "$model" >&2
    model="claude-sonnet-4-6"
  fi
  printf '%s' "$model"
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
  # Worker model is config-driven + complexity-routed (see _worker_model_for): a complex-looking
  # item runs on worker_model_complex (if set), everything else on worker_model (default sonnet);
  # worker_fallback_model, if set, is passed as --fallback-model so the CLI auto-falls-back when
  # the chosen model is unavailable/rate-limited.
  local _wmodel _wfb; _wmodel="$(_worker_model_for "$item")"
  _wfb="$(_config_get worker_fallback_model)"
  local -a _wm_args=( --model "$_wmodel" )
  [[ -n "$_wfb" ]] && _valid_model_id "$_wfb" && _wm_args+=( --fallback-model "$_wfb" )
  DEPUTY_GUARDED=1 DEPUTY_HEADLESS="$_headless" DEPUTY_ACTIVE_RUN_PID="$$" DEPUTY_WT="$(_wt_path)" DEPUTY_ROOT="$ROOT" \
    _sandbox_worker claude -p "$prompt" "${_wm_args[@]}" \
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
# (fresh per attempt). Falls back to a mktemp when the item has no file-safe item id.
_run_log_path() {
  local line="$1" id
  id="$(_parse_item "$line")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  if _valid_item_id "$id" && : > "$STATE_DIR/run-$id.log" 2>/dev/null; then
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
  if _valid_item_id "$id" && [[ "$log" == "$STATE_DIR/run-$id.log" ]]; then
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

# #87: newest FILE mtime (epoch) under THIS item's waypoint dir — the worker "real progress"
# signal. Each `deputy commit` UPDATES waypoint.json (advancing its mtime), so this rises on
# every committed step. Scoped to the running item (matched by id across both slug
# conventions) so an unrelated `deputy start` elsewhere can't reset a hung worker's timer.
# NOTE: the waypoints DIR mtime does NOT rise on an in-place file update, so dir-mtime would
# miss per-step progress; the run log updates even during a death-loop, so it is not a
# progress signal either. Empty output = no waypoint yet (counts as no-progress).
_wp_progress_stamp() {
  local id="$1" d
  for d in "$STATE_DIR"/waypoints/*-"$id" "$STATE_DIR"/waypoints/"$id"-*; do
    [[ -d "$d" ]] && { find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1; return 0; }
  done
  return 0
}

# #87: on a watchdog trip — surface the hung item (fires the notify + shows in `deputy
# watch`), write a diagnosis note, then stop the worker group: SIGTERM, a short grace so an
# in-flight (ms-long) BACKLOG write can finish, then SIGKILL. cmd_run's normal post-run
# handling (retry budget / circuit-breaker) still runs afterward on the returned non-zero rc.
_watchdog_trip() {
  local wpid="$1" item="$2" cap="$3" id slug note
  id="$(_parse_item "$item")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  printf 'deputy: WATCHDOG — no waypoint progress in %s min; surfacing #%s and stopping the worker.\n' "$cap" "${id:-?}" >&2
  if _valid_item_id "$id"; then
    slug="$(_wp_slug "$id" "watchdog timeout")"; note="$(_trail_path questions "$slug")"
    mkdir -p "$(dirname "$note")" 2>/dev/null || true
    printf 'WATCHDOG TIMEOUT (#87): no waypoint progress for %s min — the worker was killed as a suspected hang. Check the run log (%s/logs/%s.log), then resume via /deputy or resolve as appropriate.\n' "$cap" "$STATE_DIR" "$id" > "$note" 2>/dev/null || true
  fi
  # Surface BEFORE the kill, so the state flips while the worker still holds 'running'.
  cmd_set "$item" surfaced >/dev/null 2>&1 || true
  kill -TERM -- "-$wpid" 2>/dev/null || true
  sleep "${DEPUTY_WATCHDOG_GRACE_SECS:-5}"
  kill -0 "$wpid" 2>/dev/null && kill -KILL -- "-$wpid" 2>/dev/null || true
}

# #87: background watchdog for a headless worker. Trips if there is NO waypoint progress (a
# committed step) for watchdog_mins (default 45; set 0 to disable) — surfacing the item and
# stopping the worker so a hung/looping worker can't burn tokens or hold the slot forever.
# Runs as a deputy child OUTSIDE the worker's pgroup so `kill -- -$wpid` hits only the worker.
# Test seams: DEPUTY_WATCHDOG_SECS overrides the cap (seconds); DEPUTY_WATCHDOG_POLL_SECS the poll.
_run_watchdog() {
  local wpid="$1" item="$2" cap poll cap_secs last ref now cur id
  id="$(_parse_item "$item")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  cap="$(_config_get watchdog_mins)"; cap="${cap:-45}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=45
  cap_secs="${DEPUTY_WATCHDOG_SECS:-$(( cap * 60 ))}"
  [[ "$cap_secs" =~ ^[0-9]+$ && "$cap_secs" -gt 0 ]] || return 0   # 0 / invalid → disabled
  poll="${DEPUTY_WATCHDOG_POLL_SECS:-30}"
  last="$(date +%s)"; ref="$(_wp_progress_stamp "$id")"
  while kill -0 "$wpid" 2>/dev/null; do
    sleep "$poll"
    cur="$(_wp_progress_stamp "$id")"
    if [[ "$cur" != "$ref" ]]; then ref="$cur"; last="$(date +%s)"; continue; fi
    now="$(date +%s)"
    if (( now - last >= cap_secs )); then
      cur="$(_wp_progress_stamp "$id")"; if [[ "$cur" != "$ref" ]]; then ref="$cur"; last="$now"; continue; fi
      kill -0 "$wpid" 2>/dev/null || return 0
      _watchdog_trip "$wpid" "$item" "$cap"
      return 0
    fi
  done
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
    # #87: background watchdog — kills a no-waypoint-progress worker + surfaces it.
    local _wdpid=""; _run_watchdog "$wpid" "$item" & _wdpid=$!
    wait "$wpid"; rc=$?
    # Stop the watchdog (no-op if it already tripped and exited): kill its process + group.
    [[ -n "$_wdpid" ]] && { kill "$_wdpid" 2>/dev/null; kill -- -"$_wdpid" 2>/dev/null; wait "$_wdpid" 2>/dev/null; }
    [[ "$wpid" =~ ^[0-9]+$ && "$wpid" != "$_self_pgid" ]] && kill -TERM -- "-$wpid" 2>/dev/null
    [[ "$_had_m" -eq 1 ]] || set +m
    cat "$log"
  fi
  [[ "$_had_e" -eq 1 ]] && set -e
  return "$rc"
}

# #97: runner-side auto-merge (runs UNSANDBOXED, in cmd_run). A headless worker surfaces its
# branch as ready-merge — it CAN'T merge, because the #64 bwrap sandbox makes the repo code
# read-only to it (a `git merge` into the main tree would fail). So the runner does the merge
# here after the worker returns. No-op unless ALL hold: auto_merge=1, a .deputy/ready-merge-<id>
# marker exists (so a *blocking* surface without the marker is never merged), the main tree is
# on the default branch, and the tree permits the merge (#111 — a clean index with dirty paths
# DISJOINT from what the merge writes; not "pristine", see _merge_tree_blocker). On a
# clean merge: item→done, markers cleared, opt-in branch delete. On conflict: abort + leave
# surfaced with a note. Never pushes.
# Returns 0 whenever a MERGE HAPPENED — item marked done (cleanup done), OR merged-but-the
# done-write-failed (marker kept for retry) — so the caller skips retry-budget/failure handling
# and never fails an already-merged item. Returns 1 only when NO merge occurred (no-op / skip
# / conflict-aborted).
# Merge a resolved deputy/<slug> branch into the default branch. UNSANDBOXED callers only
# (the runner's cmd_run and the interactive 'deputy pickup') — a sandboxed worker can't write
# the repo. Shared by _auto_merge_ready and cmd_pickup so the merge/done/cleanup is identical.
# Preconditions (checked here): branch exists, HEAD on the default branch, and the main tree
# permits the merge (see _merge_tree_blocker — NOT "pristine"). On success: item→done,
# ready-merge/proposed markers cleared, opt-in merged-branch delete. Status text is printed to
# stdout (callers route it). rc classes (#112):
#   0 = MERGED (item done, OR merged-but-done-write-failed → marker kept, never falsely failed)
#   1 = TERMINAL-INVARIANT — branch missing/unresolvable; a human must look
#   2 = CONTENT CONFLICT — deputy cannot resolve it; note written; a human must look
#   3 = TRANSIENT precondition — the human's tree blocks it right now; park in pending-merge
#       and retry on a later tick, charging one strike
#   4 = GLOBAL SKIP — the repo is not on the default branch, which blocks EVERY parked item
#       equally; skip the drain WITHOUT charging any item a strike

# #111: print the human's dirty paths (modified / untracked / rename destinations), one per
# line. Uses --porcelain -z so paths with spaces or non-ASCII bytes are never quoted or split,
# and -uall so untracked files are listed INDIVIDUALLY: the default (-unormal) collapses them
# into their containing directory ('newdir/'), which would never match a merge-affected path
# like 'newdir/file.txt' in the exact-match intersection and would let a real overlap through.
# BACKLOG.md and .deputy/ are deputy-owned and self-committed by the runner, so their transient
# state is not the human's dirt and never blocks a merge.
_main_tree_dirty_paths() {
  local entry path
  while IFS= read -r -d '' entry; do
    path="${entry:3}"
    # In -z format a rename/copy entry is followed by a SECOND field holding the original
    # path — consume it so it is not mistaken for the next status entry.
    case "${entry:0:1}" in R|C) IFS= read -r -d '' _ || true ;; esac
    [[ "$path" == "BACKLOG.md" || "$path" == .deputy/* ]] && continue
    printf '%s\n' "$path"
  done < <(git -C "$ROOT" status --porcelain -z -uall 2>/dev/null)
}

# #111: may we run `git merge <branch>` in the main tree RIGHT NOW? Prints a reason and returns
# 1 when not; prints nothing and returns 0 when yes.
#
# Deputy used to demand that `git status --porcelain` be completely EMPTY. That is far stricter
# than git itself, and it made the ordinary case — a human with unrelated work-in-progress in
# the tree — surface a "merge blocked, do it by hand" note for a merge git would have performed
# happily. git's real rules (verified empirically):
#   * the INDEX must be clean: ANY staged change makes the ort strategy refuse, even one that
#     does not overlap the merge at all;
#   * unstaged modifications are fine so long as the merge does not need to write those paths —
#     git preserves them, and they stay OUT of the merge commit;
#   * untracked files are fine unless the merge would create that same path.
# So: require a clean index, and require the paths the merge writes to be DISJOINT from the
# human's dirty paths. Everything else keeps the old surface-for-a-manual-merge behaviour.
# Set merge_dirty_disjoint=0 to restore the strict pristine-tree rule.
_merge_tree_blocker() {
  local branch="$1" staged affected overlap
  if [[ "$(_config_get merge_dirty_disjoint)" == "0" ]]; then
    [[ -z "$(_main_tree_dirty_paths)" ]] && return 0
    printf 'the main tree is dirty (merge_dirty_disjoint=0 — strict pristine-tree rule)'; return 1
  fi
  staged="$(git -C "$ROOT" diff --cached --name-only 2>/dev/null | head -5 | tr '\n' ' ')" || true
  [[ -z "$staged" ]] || { printf 'the main tree has staged changes (git refuses to merge with a dirty index): %s' "${staged% }"; return 1; }
  # Paths this merge will write = what changed on the BRANCH side since the merge base.
  affected="$(git -C "$ROOT" diff --name-only "HEAD...$branch" 2>/dev/null)" || true
  [[ -n "$affected" ]] || return 0        # merge writes nothing → nothing can be clobbered
  # Compare by PATH NAMESPACE, not string equality: a dirty path also blocks a merge when one
  # side is an ancestor of the other. An untracked FILE named 'sub' stops the merge from
  # creating 'sub/nested.txt' (and vice versa), and an exact-match intersection would miss it.
  # With no dirty paths the inner loop never runs, so a clean tree short-circuits here.
  overlap="$(awk 'NR==FNR{d[FNR]=$0; n=FNR; next}
                  { for(i=1;i<=n;i++){ p=d[i]
                      if ($0==p || index($0, p "/")==1 || index(p, $0 "/")==1) { print; next } } }' \
             <(_main_tree_dirty_paths) <(printf '%s\n' "$affected") 2>/dev/null | head -5 | tr '\n' ' ')" || true
  [[ -z "$overlap" ]] || { printf 'the main tree has uncommitted changes to files this merge writes: %s' "${overlap% }"; return 1; }
  return 0
}

# #112: will <branch> merge cleanly into <def>? Answered WITHOUT touching the index or the
# worktree, so it is valid even while the human's tree is dirty — which is the entire point:
# a branch that can NEVER merge cleanly needs a human, so it must surface immediately instead
# of being parked and retried until the strike budget runs out.
# rc 0 = merges cleanly · 1 = conflicts · 2 = UNKNOWN (git <2.38 has no --write-tree, or the
# probe failed). On UNKNOWN the caller must not conclude anything and should fall back to
# parking + retrying, exactly as before.
_merge_conflict_predetect() {
  local def="$1" branch="$2" rc=0
  git -C "$ROOT" merge-tree --write-tree "$def" "$branch" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

_merge_ready_branch() {
  local id="$1" branch="$2" def cur blocker marker="$STATE_DIR/ready-merge-$id"
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || { printf 'branch %s is missing\n' "$branch"; return 1; }
  def="$(_default_branch)"; cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  # NOT on the default branch is a property of the REPO, not of this item — every parked item
  # is equally blocked by it. Class 4 so the caller skips the whole drain without charging any
  # item a strike (otherwise a fortnight on a feature branch would surface every parked item).
  [[ -n "$def" && "$cur" == "$def" ]] || { printf 'not on the default branch (on %s; need %s) — merge manually: git checkout %s && git merge --no-ff %s\n' "${cur:-?}" "${def:-?}" "${def:-<default>}" "$branch"; return 4; }
  # Ask git whether this branch can EVER merge cleanly, before worrying about the tree state.
  # A conflict needs a human no matter how long we wait, so it must not be parked.
  # '|| _pd=$?' — NOT a bare call: under `set -e` a bare non-zero here would abort before the
  # conflict/UNKNOWN handling below for any caller that does not already wrap this function in
  # a `||` list (the drain calls it directly).
  local _pd=0; _merge_conflict_predetect "$def" "$branch" || _pd=$?
  if [[ "$_pd" -eq 1 ]]; then
    local note; note="$(_trail_path questions "${branch#deputy/}")"; mkdir -p "$(dirname "$note")" 2>/dev/null || true
    printf 'MERGE CONFLICT: %s does not merge cleanly into %s. Resolve manually: git checkout %s && git merge --no-ff %s\n' "$branch" "$def" "$def" "$branch" >> "$note" 2>/dev/null || true
    printf '%s conflicts with %s — needs you; deputy cannot resolve it (see %s)\n' "$branch" "$def" "$note"; return 2
  fi
  if ! blocker="$(_merge_tree_blocker "$branch")"; then
    printf '%s — commit/stash those, then: git merge --no-ff %s\n' "$blocker" "$branch"; return 3
  fi
  if ! git -C "$ROOT" merge --no-ff "$branch" -m "deputy: merge $branch (#$id)" >/dev/null 2>&1; then
    # Distinguish git's ATOMIC pre-merge refusal (index and worktree untouched, MERGE_HEAD never
    # written, nothing to abort) from a real content conflict. Aborting unconditionally — and
    # calling every failure a CONFLICT — would mislabel a tree that merely changed under us
    # between the check above and the merge.
    if ! git -C "$ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      printf 'git refused the merge (the main tree changed since the check) — retry, or merge manually: git merge --no-ff %s\n' "$branch"; return 3
    fi
    git -C "$ROOT" merge --abort 2>/dev/null || true
    local note; note="$(_trail_path questions "${branch#deputy/}")"; mkdir -p "$(dirname "$note")" 2>/dev/null || true
    printf 'MERGE CONFLICT: %s does not merge cleanly into %s. Resolve manually: git checkout %s && git merge --no-ff %s\n' "$branch" "$def" "$def" "$branch" >> "$note" 2>/dev/null || true
    printf '%s conflicts with %s — aborted; resolve manually (see %s)\n' "$branch" "$def" "$note"; return 2
  fi
  # Merge succeeded. Clear markers + delete the branch ONLY if the done-write succeeds, so a
  # failed BACKLOG write leaves the marker for retry rather than losing the item.
  local cur_line; cur_line="$(_line_by_id "$id" || true)"
  # #113(D): finalize the WAYPOINT ledger too, and run the outcome gate.
  # Until now this path wrote only BACKLOG.md, so every runner-auto-merged item left
  # waypoint.json saying "in_progress" while the queue said Done — the two records
  # disagreeing on literally every auto-merge. cmd_wp_done also enforces the acceptance
  # gate: when the item HAS a criterion that was never proven, the merge still stands (the
  # code was reviewed and tested) but the item must NOT be closed as done — it surfaces.
  # Items with no waypoint, or no acceptance record, are unaffected.
  local _slug="" _wp_rc=0 _wp_err=""
  _slug="$(cmd_slug "$id" 2>/dev/null | head -1 || true)"
  if [[ -n "$_slug" && -f "$(_wp_json "$_slug")" ]]; then
    _wp_err="$(cmd_wp_done "$_slug" 2>&1 >/dev/null)" || _wp_rc=$?
  fi
  if [[ "$_wp_rc" -ne 0 ]]; then
    local note; note="$(_trail_path questions "$_slug")"
    mkdir -p "$(dirname "$note")" 2>/dev/null || true
    { printf 'MERGED BUT NOT CLOSED: %s is merged into %s, but deputy will not call it done.\n\n' "$branch" "$def"
      printf '%s\n\n' "$_wp_err"
      printf 'The code landed; what is unproven is that YOUR reported symptom is gone.\n'
      printf 'Resolve with:  deputy verify %s --green && deputy verify %s --bite && deputy done %s\n' "$_slug" "$_slug" "$_slug"
      printf 'Or close it deliberately:  deputy done %s --no-verify\n' "$_slug"
    } >> "$note" 2>/dev/null || true
    if [[ -n "$cur_line" ]] && cmd_set "$cur_line" surfaced >/dev/null 2>&1; then
      rm -f "$marker" "$STATE_DIR/proposed-$id" 2>/dev/null || true
      printf 'merged %s into %s — #%s SURFACED (not done): the reported symptom is not proven fixed (see %s)\n' "$branch" "$def" "$id" "$note"
      return 0
    fi
    printf 'merged %s into %s but could not surface #%s — marker kept; resolve manually\n' "$branch" "$def" "$id"
    return 0
  fi
  if [[ -n "$cur_line" ]] && cmd_set "$cur_line" done >/dev/null 2>&1; then
    rm -f "$marker" "$STATE_DIR/proposed-$id" 2>/dev/null || true
    if _should_delete_merged_branch && git -C "$ROOT" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
      git -C "$ROOT" branch -d "$branch" >/dev/null 2>&1 || true
    fi
    printf 'merged %s into %s — #%s done\n' "$branch" "$def" "$id"; return 0
  fi
  printf 'merged %s into %s but failed to mark #%s done — marker kept; resolve manually\n' "$branch" "$def" "$id"; return 0
}

# #97/#98/#99: runner-side auto-merge. A headless worker surfaces its branch ready-merge (it
# CAN'T merge — the #64 sandbox makes the repo read-only to it); the UNSANDBOXED runner merges
# here after the worker returns, WHEN auto_merge=1. No-op unless: auto_merge=1, a ready-merge
# marker exists (so a blocking surface is never merged), and the branch resolves (#98/#99).
# Returns 0 whenever the outcome was HANDLED (#112) — merged, or routed to pending-merge /
# surfaced — so the caller skips the waypoint retry-budget. That budget marks an item FAILED
# when spent, and an item we just parked or surfaced is no longer running, so it must never
# reach it. Returns 1 only when nothing was done (auto_merge=0, no ready-merge marker, or the
# routing itself failed), leaving the caller's pre-existing behaviour intact.
# #112: apply ONE merge attempt's outcome to the item. Shared by the post-run auto-merge and
# the runner's drain so both route identically. The human's rule: a merge-ready task must never
# sit in their pickup queue, so only outcomes deputy genuinely cannot resolve are surfaced.
#   rc 1 TERMINAL   -> surface now, and DROP the ready-merge marker so _surfaced_kind reports
#                      "needs input" rather than advertising a "ready to merge" item that
#                      pickup could never merge.
#   rc 2 CONFLICT   -> surface now (a human must resolve it); marker dropped for the same reason.
#   rc 3 TRANSIENT  -> park in pending-merge and charge one strike; at merge_retry_strikes
#                      consecutive strikes, escalate to surfaced so it can never sit forever.
#   rc 4 GLOBAL     -> park in pending-merge, charge NOTHING: the repo being off the default
#                      branch blocks every parked item equally and says nothing about this item.
# Always re-resolves the item's CURRENT line by id — the caller's line is stale the moment the
# worker transitioned the item, and a stale whole-line match silently no-ops.
_merge_route_outcome() {
  local id="$1" rc="$2" msg="$3" line cap n
  line="$(_line_by_id "$id" || true)"
  [[ -n "$line" ]] || { printf 'deputy: #%s vanished from the queue — cannot route merge outcome\n' "$id" >&2; return 1; }
  # The ready-merge marker is the ONLY record of which branch to merge, so it is dropped only
  # AFTER the surfacing transition actually succeeds. Dropping it first would strand the item
  # with no branch whenever cmd_set failed (a stale line, an unwritable BACKLOG).
  _surface_and_drop_marker() {
    local _l="$1" _n="$2"
    if cmd_set "$_l" surfaced >/dev/null 2>&1; then
      rm -f "$STATE_DIR/ready-merge-$_n" 2>/dev/null || true
      _mergefail_reset "$_n"; return 0
    fi
    printf 'deputy: failed to surface #%s — marker kept so the merge can be retried\n' "$_n" >&2
    return 1
  }
  case "$rc" in
    1|2) _surface_and_drop_marker "$line" "$id"; return $? ;;
    4)   cmd_set "$line" pending-merge >/dev/null 2>&1 || return 1
         return 0 ;;
    3)
      cap="$(_config_get merge_retry_strikes)"; _valid_positive_int "$cap" || cap=10
      n="$(_mergefail_bump "$id" "$msg")"
      if [[ "$n" -ge "$cap" ]]; then
        # Write the note under a slug _questions_file can actually FIND: it globs
        # '<id>-*.md' / '*-<id>.md', so a bare '<id>.md' would be invisible in the detail block.
        local note; note="$(_trail_path questions "$(_wp_slug "$id" "merge still blocked")")"
        mkdir -p "$(dirname "$note")" 2>/dev/null || true
        printf 'MERGE STILL BLOCKED after %s attempts: %s\nDeputy kept retrying and could not land it — your call.\n' "$n" "$msg" >> "$note" 2>/dev/null || true
        _surface_and_drop_marker "$line" "$id" || return 1
        printf 'deputy: #%s still unmergeable after %s attempts — surfaced for you\n' "$id" "$n" >&2
      else
        cmd_set "$line" pending-merge >/dev/null 2>&1 || return 1
      fi
      return 0 ;;
  esac
  return 1
}

_auto_merge_ready() {
  local item="$1" id branch
  id="$(_parse_item "$item")"; id="${id#*|}"; id="${id#*|}"; id="${id%%|*}"
  _valid_item_id "$id" || return 1
  [[ "$(_config_get auto_merge)" == "1" ]] || return 1
  [[ -f "$STATE_DIR/ready-merge-$id" ]] || return 1     # not ready (blocking surface / n/a)
  branch="$(_ready_merge_branch "$id" || true)"
  [[ "$branch" == deputy/* ]] || {
    printf 'deputy: auto_merge: #%s has no resolvable branch (none recorded / ambiguous) — surfaced for a human\n' "$id" >&2
    _merge_route_outcome "$id" 1 "no resolvable deputy/* branch (none recorded / ambiguous)" && return 0
    return 1; }
  local _msg _rc=0
  # '|| _rc=$?' so a non-zero merge result doesn't trip set -e before we capture/print it.
  _msg="$(_merge_ready_branch "$id" "$branch")" || _rc=$?
  printf 'deputy: auto_merge: %s\n' "$_msg" >&2
  # #112: a blocked merge is deputy's problem, not the human's — route it rather than leaving
  # it surfaced. rc 0 needs no routing (the merge already marked the item done).
  [[ "$_rc" -eq 0 ]] && return 0
  # RETURN 0 WHENEVER THE OUTCOME WAS HANDLED, not only when a merge happened. The caller uses
  # this to decide whether to fall through to the waypoint retry-budget, and that logic marks
  # the item FAILED when the budget is spent. An item we just parked in pending-merge (or
  # surfaced) is no longer running, so letting it reach that path would fail a perfectly
  # healthy, already-dispositioned item.
  _merge_route_outcome "$id" "$_rc" "$_msg" && return 0
  return 1               # genuinely unhandled — caller keeps its existing behaviour
}

# #112: drain parked merges. The human's rule is that a merge-ready task must NEVER sit in
# their pickup queue, so a merge blocked by their working tree parks in pending-merge and is
# retried HERE — at the top of every tick, before any new item is claimed. Placed before the
# default-branch refusal so the drain can never be dead code.
#
# NEVER stalls the queue: an item that still cannot merge simply stays parked and the tick
# carries on to waiting work. Bounded by merge_drain_limit so a large backlog of parked
# branches can't all land in one unattended tick.
_drain_pending_merges() {
  local raw parsed state id
  local -a ids=()
  [[ "$(_config_get auto_merge)" == "1" ]] || return 0
  # A merge WRITES the human's working tree, so the drain is subject to the same human-session
  # back-off as claiming an item. Without this an unattended tick could merge files out from
  # under a live interactive session — the exact hazard human_backoff exists to prevent.
  if _human_backoff_gate; then return 0; fi
  _live_claim_exists && return 0
  # Collect ids FIRST: _merge_route_outcome rewrites BACKLOG.md via cmd_set, and iterating the
  # file while mutating it would read a torn or stale stream. Numeric sort = oldest parked first.
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    [[ "$state" == "pending-merge" ]] || continue
    id="${parsed#*|}"; id="${id#*|}"; id="${id%%|*}"
    _valid_item_id "$id" && ids+=("$id")
  done < <(_each_item)
  [[ "${#ids[@]}" -gt 0 ]] || return 0
  # Take the SAME flock-atomic guard cmd_run uses before claiming an item. Merely TESTING
  # _active_run_live and then merging is a TOCTOU window: two overlapping ticks could merge
  # concurrently, or this drain could merge while another tick is claiming/spawning work.
  # rc 3 = someone else holds it, which is a normal skip, not an error.
  _active_run_acquire "pending-merge drain" "run" || return 0
  _drain_pending_merges_locked "${ids[@]}" || true   # single exit -> the release always runs
  _active_run_release
  return 0
}

# The drain body. Never returns non-zero; the caller releases the guard unconditionally.
_drain_pending_merges_locked() {
  local limit n=0 id branch msg rc cur st
  limit="$(_config_get merge_drain_limit)"; _valid_positive_int "$limit" || limit=10
  for id in "$@"; do
    if (( n >= limit )); then
      printf 'deputy: pending-merge drain: stopping at merge_drain_limit=%s — the rest retry next tick\n' "$limit" >&2
      break
    fi
    # RE-VERIFY under the guard. The id list was gathered BEFORE the guard was held (so a tick
    # with nothing parked never has to take it), which means an overlapping tick may have
    # merged this item in the meantime. Acting on a stale id would mutate an already-done item.
    # Skipped stale ids must not consume the budget, so this precedes the increment.
    cur="$(_line_by_id "$id" || true)"
    [[ -n "$cur" ]] || continue
    st="$(_parse_item "$cur")"; st="${st%%|*}"
    [[ "$st" == "pending-merge" ]] || continue
    # Count EVERY item processed, not just merge attempts — an unresolvable-branch item still
    # mutates BACKLOG.md, so excluding it would let the limit be exceeded in practice.
    n=$(( n + 1 ))
    branch="$(_ready_merge_branch "$id" || true)"
    if [[ "$branch" != deputy/* ]]; then
      _merge_route_outcome "$id" 1 "no resolvable deputy/* branch (none recorded / ambiguous)" || true
      continue
    fi
    rc=0; msg="$(_merge_ready_branch "$id" "$branch")" || rc=$?
    printf 'deputy: pending-merge drain: #%s: %s\n' "$id" "$msg" >&2
    # Class 4 is repo-wide (not on the default branch): every parked item is equally blocked,
    # and charging strikes would eventually surface perfectly healthy items. Abandon the sweep
    # without touching a single item.
    [[ "$rc" -eq 4 ]] && return 0
    [[ "$rc" -eq 0 ]] || _merge_route_outcome "$id" "$rc" "$msg" || true
  done
  return 0
}

# 'deputy pickup #<id>' — bring up ONE task and ACT on it (the interactive counterpart to the
# read-only 'deputy list' detail and the passive 'deputy watch' summon). Works on a task in an
# ATTENTION state; shows the item + its detail, then performs the safe action:
#   surfaced · ready-to-merge → merge into the default branch (→ done)
#   surfaced · proposed       → approve (→ waiting)
#   surfaced · needs-input    → point to /deputy (a conversation can't be auto-resumed)
#   failed / cancelled / deferred / paused → requeue (→ waiting)
# Safe/local only — never pushes or deletes anything outward.
cmd_pickup() {
  local id="$1"
  # NOTE: prefer the bare-integer form — an UNQUOTED '#42' is a shell comment, so
  # `deputy pickup #42` reaches deputy with no args. Use `deputy pickup 42` or quote: '#42'.
  [[ -n "$id" ]] || { printf 'deputy: pickup requires an <id> — e.g. "deputy pickup 42" (a bare #42 is a shell comment; quote it as "#42")\n' >&2; return 2; }
  id="${id#\#}"
  _valid_item_id "$id" || { printf 'deputy: pickup: invalid id: %s\n' "$id" >&2; return 2; }
  _with_lock _allocate_ids
  # Anchor the id tag to the line start (after an optional 1-char status prefix) so a "[#id]"
  # mention in another task's description can't be matched instead. Escape the id's '.' (a
  # sub-id like 145.2) so the ERE doesn't treat it as a wildcard (_id_re).
  local line pi state
  line="$(grep -E "^[^[]?\[#$(_id_re "$id")\]" "$BACKLOG" 2>/dev/null | head -1 || true)"
  [[ -n "$line" ]] || { printf 'deputy: pickup: no task #%s found\n' "$id" >&2; return 1; }
  pi="$(_parse_item "$line")"; state="${pi%%|*}"
  printf '%s\n' "$line"
  _item_detail_block "$state" "$id"
  printf '\n'
  case "$state" in
    surfaced)
      local kind; kind="$(_surfaced_kind "$id")"
      case "$kind" in
        "ready to merge")
          local branch _msg _rc=0; branch="$(_ready_merge_branch "$id" || true)"
          [[ "$branch" == deputy/* ]] || {
            printf 'deputy: pickup: #%s is ready-to-merge but its branch is unresolvable (none recorded / ambiguous) — resolve manually.\n' "$id" >&2
            # #112: route as terminal so the stale ready-merge marker is dropped — otherwise the
            # item keeps advertising a "merge" action that can never work.
            _merge_route_outcome "$id" 1 "no resolvable deputy/* branch (none recorded / ambiguous)" || true
            return 1; }
          # '|| _rc=$?' so a non-zero merge result doesn't trip set -e before we print the reason.
          _msg="$(_merge_ready_branch "$id" "$branch")" || _rc=$?
          printf 'deputy: pickup: %s\n' "$_msg"
          [[ "$_rc" -eq 0 ]] && return 0
          # #112: route the failure like every other merge attempt — a transient blocker parks
          # the item (deputy retries it; the human is not asked again) and a conflict drops the
          # ready-merge marker so it stops advertising itself as "ready to merge".
          _merge_route_outcome "$id" "$_rc" "$_msg" || true
          return 1 ;;
        "proposed")
          if cmd_set "$line" waiting >/dev/null 2>&1; then
            rm -f "$STATE_DIR/proposed-$id" 2>/dev/null || true
            printf 'deputy: pickup: approved proposal #%s → waiting (runs in priority order).\n' "$id"; return 0
          fi
          printf 'deputy: pickup: failed to approve #%s\n' "$id" >&2; return 1 ;;
        *)  # needs input — cannot auto-resume a conversation
          printf 'deputy: pickup: #%s needs your input — run /deputy to resume it from its waypoint (details above).\n' "$id"; return 0 ;;
      esac ;;
    pending-merge)
      # #112: deputy already owns this merge and retries it every tick; pickup just does it NOW
      # (e.g. the human cleared the blocker and does not want to wait for the next tick).
      local _pm_branch _pm_msg _pm_rc=0
      _pm_branch="$(_ready_merge_branch "$id" || true)"
      [[ "$_pm_branch" == deputy/* ]] || {
        printf 'deputy: pickup: #%s is pending-merge but its branch is unresolvable — surfacing it for you.\n' "$id" >&2
        # #112: MUST surface. pending-merge is a non-attention state, so returning here would
        # leave the item parked and silent forever even though nothing can ever complete it.
        _merge_route_outcome "$id" 1 "no resolvable deputy/* branch (none recorded / ambiguous)" || true
        return 1; }
      _pm_msg="$(_merge_ready_branch "$id" "$_pm_branch")" || _pm_rc=$?
      printf 'deputy: pickup: %s\n' "$_pm_msg"
      [[ "$_pm_rc" -eq 0 ]] && return 0
      _merge_route_outcome "$id" "$_pm_rc" "$_pm_msg" || true
      return 1 ;;
    failed|cancelled|deferred|paused)
      if cmd_set "$line" waiting >/dev/null 2>&1; then
        printf 'deputy: pickup: #%s (%s) → waiting (requeued; runs in priority order).\n' "$id" "$state"; return 0
      fi
      printf 'deputy: pickup: failed to requeue #%s\n' "$id" >&2; return 1 ;;
    *)
      printf 'deputy: pickup: #%s is %s — pickup only acts on surfaced/pending-merge/failed/cancelled/paused/deferred tasks.\n' "$id" "$state" >&2; return 2 ;;
  esac
}

# One tick: claim the top item and hand it to the orchestrator. --once = no loop.
# If an integer <id> is given (deputy run <id> or deputy run '#<id>'), run that
# specific item bypassing priority, then return (targeted = one item only).
cmd_run() {
  local once=0 target_id="" _RUN_HEADLESS=0
  # add+run mode: --p0..--p4 (and -ui/-u/-i aliases) followed by a description
  local _add_prio="" _add_text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      --headless) _RUN_HEADLESS=1; shift ;;
      --p0|-ui) _add_prio="--p0"; shift ;;
      --p1|-u)  _add_prio="--p1"; shift ;;
      --p2|-i)  _add_prio="--p2"; shift ;;
      --p3)     _add_prio="--p3"; shift ;;
      --p4)     _add_prio="--p4"; shift ;;
      '#'*) target_id="${1#'#'}"; shift ;;
      *)
        if [[ -n "$_add_prio" ]]; then
          # After a priority flag: all remaining args form the description
          _add_text="${_add_text}${_add_text:+ }$1"; shift
        elif _valid_item_id "$1"; then
          target_id="$1"; shift
        elif [[ -n "$1" ]]; then
          printf 'deputy: run: id must be a positive integer, optionally with a .N sub-id (got: %s)\n' "$1" >&2; return 2
        else
          shift
        fi
        ;;
    esac
  done

  # Validate target_id: strip leading # and verify it's a valid item id (int or int.sub)
  if [[ -n "$target_id" ]]; then
    target_id="${target_id#'#'}"
    if ! _valid_item_id "$target_id"; then
      printf 'deputy: run: id must be a positive integer, optionally with a .N sub-id (got: %s)\n' "$target_id" >&2; return 2
    fi
  fi

  # add+run mode validation: --<prio> requires a description; conflicts with explicit target_id
  if [[ -n "$_add_prio" ]]; then
    [[ -n "$_add_text" ]] || { printf 'deputy: run: %s requires a description\n' "$_add_prio" >&2; return 2; }
    [[ -z "$target_id" ]] || { printf 'deputy: run: cannot combine a priority flag with a target id\n' >&2; return 2; }
  fi

  # #57 (Part B): warn (never kill) about leaked long-running orphans under in-repo
  # Claude sessions that could pin a session busy and stall the heartbeat. Best-effort.
  _warn_stale_orphans || true

  # ── Default-branch guard ────────────────────────────────────────────────────
  # Refuse to run if the repo is on a feature branch. This prevents the cron
  # (cd <repo> && deputy run) from running against un-merged code.
  # Bypass: set DEPUTY_ALLOW_ANY_BRANCH=1 (tests / deliberate use).
  # #112: land any merge parked by an earlier tick before doing anything else — including
  # before the default-branch refusal below, so the drain is reachable on every tick.
  _drain_pending_merges || true

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
  # Non-targeted (cron/heartbeat) path: silent skip when any live claim exists.
  # The targeted path and add+run mode both get their own priority-aware checks instead.
  if [[ -z "$target_id" && -z "$_add_prio" ]] && _live_claim_exists; then return 0; fi

  # ── Add+run mode — Phase 1: add the task (before the human-session gate) ─────
  # The add always happens: the user explicitly asked to queue this task. Only the
  # *run* decision is gated by human-session back-off. Stdout from cmd_add is captured
  # so we can detect "already present" (which returns 0 from cmd_add, not an error).
  local _ar_id="" _ar_prio="" _ar_rank=99 _ar_out="" _ar_rc=0 _ar_raw _ar_parsed _ar_rest
  if [[ -n "$_add_prio" ]]; then
    # DEPUTY_NO_AUTORUN=1 prevents cmd_add from spawning _autorun before our decision.
    _ar_out="$( export DEPUTY_NO_AUTORUN=1; cmd_add "$_add_prio" "$_add_text" )" || _ar_rc=$?
    printf '%s\n' "$_ar_out"
    [[ "$_ar_rc" -ne 0 ]] && return "$_ar_rc"
    # If the task already existed, nothing to run (the "already present" message was printed).
    [[ "$_ar_out" == *"already present"* ]] && return 0
    # Look up the new item's ID by description — BACKLOG is the source of truth.
    while IFS= read -r _ar_raw; do
      _ar_parsed="$(_parse_item "$_ar_raw")"
      _ar_rest="${_ar_parsed#*|}"; _ar_rest="${_ar_rest#*|}"; _ar_rest="${_ar_rest#*|}"
      if [[ "$_ar_rest" == "$_add_text" ]]; then
        _ar_id="${_ar_parsed#*|}"; _ar_id="${_ar_id#*|}"; _ar_id="${_ar_id%%|*}"
        break
      fi
    done < <(_each_item)
    [[ -n "$_ar_id" ]] || return 0   # safety: couldn't resolve (shouldn't happen after a fresh add)
    case "$_add_prio" in
      --p0) _ar_prio="P0" ;; --p1) _ar_prio="P1" ;; --p2) _ar_prio="P2" ;;
      --p3) _ar_prio="P3" ;; --p4) _ar_prio="P4" ;; *) _ar_prio="P3" ;;
    esac
    _ar_rank="$(_prio_rank "$_ar_prio")"
  fi

  # ── Human-session back-off (startup check) ───────────────────────────────────
  # If an interactive Claude Code session is active in this repo, skip this heartbeat
  # tick to avoid mixing deputy commits with the human's uncommitted work.
  # For add+run mode the task is already queued above — only the run is gated here.
  # Disable with: deputy config set human_backoff 0
  # Note: DEPUTY_ALLOW_ANY_BRANCH=1 does NOT bypass this check (independent guards).
  local _isa_pid="" _isa_status="" _isa_status_updated_at="" _isa_stale_pid=""
  if _human_backoff_gate; then return 0; fi

  # ── Add+run mode — Phase 2: run decision (preemption or priority queue) ──────
  if [[ -n "$_add_prio" && -n "$_ar_id" ]]; then
    # Preemption check: is there a live running claim?
    local _ar_claim_f _ar_lr_item="" _ar_lr_parsed _ar_lr_prio _ar_lr_id _ar_lr_rank
    for _ar_claim_f in "$STATE_DIR"/*.claim; do
      [[ -e "$_ar_claim_f" ]] || continue
      _claim_live "$_ar_claim_f" || continue
      _ar_lr_item="$(sed -n '1p' "$_ar_claim_f" 2>/dev/null || true)"
      break
    done
    if [[ -n "$_ar_lr_item" ]]; then
      _ar_lr_parsed="$(_parse_item "$_ar_lr_item")"
      _ar_lr_prio="${_ar_lr_parsed#*|}"; _ar_lr_prio="${_ar_lr_prio%%|*}"
      _ar_lr_id="${_ar_lr_parsed#*|}"; _ar_lr_id="${_ar_lr_id#*|}"; _ar_lr_id="${_ar_lr_id%%|*}"
      _ar_lr_rank="$(_prio_rank "$_ar_lr_prio")"
      if (( _ar_rank < _ar_lr_rank )); then
        # New task is strictly higher priority: cooperatively pause the running task.
        # This mirrors the targeted-run preemption protocol: the live claim stays until
        # the worker itself exits on its next preemption check; the next heartbeat then
        # sees no live claim and picks up the now-highest-priority new task.
        printf 'deputy: pausing #%s (%s) — #%s (%s) will run on next heartbeat.\n' \
          "$_ar_lr_id" "${_ar_lr_prio:-P?}" "$_ar_id" "${_ar_prio:-P?}"
        cmd_set "$_ar_lr_id" paused >/dev/null 2>&1 || true
      else
        # New task is equal or lower priority (tie = no preempt): leave it waiting.
        printf 'deputy: #%s (%s) is running; #%s (%s) left waiting — higher-priority task in progress.\n' \
          "$_ar_lr_id" "${_ar_lr_prio:-P?}" "$_ar_id" "${_ar_prio:-P?}"
      fi
      return 0
    fi
    # No running task: check if the new item is the highest-priority waiting item.
    # cmd_pick returns the top waiting/paused item (FIFO on ties), so if the new item
    # is not at the top, another item with equal-or-higher priority was queued first.
    local _ar_top _ar_top_parsed _ar_top_id
    _ar_top="$(cmd_pick)"
    if [[ -n "$_ar_top" ]]; then
      _ar_top_parsed="$(_parse_item "$_ar_top")"
      _ar_top_id="${_ar_top_parsed#*|}"; _ar_top_id="${_ar_top_id#*|}"; _ar_top_id="${_ar_top_id%%|*}"
      if [[ "$_ar_top_id" == "$_ar_id" ]]; then
        target_id="$_ar_id"   # new item is top priority: run it immediately via targeted path
      else
        # Another item has higher or equal priority (FIFO wins on ties): queue only.
        printf 'deputy: #%s (%s) queued — higher-priority items waiting.\n' "$_ar_id" "${_ar_prio:-P?}"
        return 0
      fi
    else
      target_id="$_ar_id"   # queue unexpectedly empty after add; run the new item
    fi
    # Falls through to the targeted-run path with target_id set.
  fi

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

    # ── Priority-aware preemption for targeted runs ───────────────────────────
    # When another item holds a live claim, compare priorities instead of silently
    # skipping. Purely cooperative: we signal the running worker by flipping its
    # BACKLOG line to paused; it exits on its next preemption check; the following
    # heartbeat then picks up the now-highest-priority target. Never removes a live
    # claim file (the worker still holds that slot until it exits cleanly).
    local _lr_claim_f _lr_item="" _lr_parsed _lr_prio _lr_id _lr_rank _tgt_parsed _tgt_prio _tgt_rank
    for _lr_claim_f in "$STATE_DIR"/*.claim; do
      [[ -e "$_lr_claim_f" ]] || continue
      _claim_live "$_lr_claim_f" || continue
      _lr_item="$(sed -n '1p' "$_lr_claim_f" 2>/dev/null || true)"
      break
    done
    if [[ -n "$_lr_item" ]]; then
      _lr_parsed="$(_parse_item "$_lr_item")"
      _lr_prio="${_lr_parsed#*|}"; _lr_prio="${_lr_prio%%|*}"
      _lr_id="${_lr_parsed#*|}"; _lr_id="${_lr_id#*|}"; _lr_id="${_lr_id%%|*}"
      _lr_rank="$(_prio_rank "$_lr_prio")"
      _tgt_parsed="$(_parse_item "$found_line")"
      _tgt_prio="${_tgt_parsed#*|}"; _tgt_prio="${_tgt_prio%%|*}"
      _tgt_rank="$(_prio_rank "$_tgt_prio")"
      if (( _tgt_rank < _lr_rank )); then
        # Target is higher priority: signal the running worker to stop cooperatively,
        # then back off. The worker exits on its next preemption check and the
        # following heartbeat picks up the target (now highest priority).
        printf 'deputy: pausing #%s (%s) — #%s (%s) will run on next heartbeat.\n' \
          "$_lr_id" "${_lr_prio:-P?}" "$target_id" "${_tgt_prio:-P?}" >&2
        cmd_set "$_lr_id" paused >/dev/null 2>&1 || true
      else
        # Target is lower or equal priority: leave it waiting and warn.
        printf 'deputy: #%s (%s) is running; #%s (%s) left waiting — higher-priority task in progress.\n' \
          "$_lr_id" "${_lr_prio:-P?}" "$target_id" "${_tgt_prio:-P?}" >&2
      fi
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
    { [[ "$rc" -eq 0 ]] && _auto_merge_ready "$running_line"; } || true   # #97: runner merges ready-merge branch when auto_merge=1 (rc==0 only)
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
      local _fail_reason="cron resume budget exhausted ($_WP_RETRY_BUDGET attempts, no step progress)"
      printf '%s\n' "$_fail_reason" > "$(_trail_path fails "$_rb_slug")"   # #70: .deputy/fails/<slug>.md
      _with_lock _do_set_item_failed "$running_line" || true
      _surface_blocked_by_failed "$_rb_id"   # #114: surface dependents whose prereq just failed
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
          printf '%s\n' "cron resume budget exhausted ($_WP_RETRY_BUDGET attempts, no step progress)" \
            > "$(_trail_path fails "$_qrb_slug")"
          local _qrb_cur_line
          _qrb_cur_line="$(_line_by_id "$_rb_id" || true)"
          if [[ -n "$_qrb_cur_line" ]]; then
            _with_lock _revert_to_waiting "$_qrb_cur_line" >/dev/null 2>&1 || true
            _qrb_cur_line="$(_line_by_id "$_rb_id" || true)"
            [[ -n "$_qrb_cur_line" ]] && { _with_lock _do_set_item_failed "$_qrb_cur_line" || true; }
            _surface_blocked_by_failed "$_rb_id"   # #114: surface dependents of now-failed prereq
          fi
        fi
      fi
      printf 'deputy: Claude session limit reached — will retry on next heartbeat tick.\n'
      _active_run_release
      return 0
    fi
    # #67 startup-crash circuit-breaker: a worker that died at spawn (rc!=0) BEFORE
    # `deputy start` created a waypoint ledger is invisible to the resume-budget (which
    # counts ledger attempts), so it would crash-loop — revert→re-pick→respawn every tick.
    # Count consecutive such spawns per item; under the limit, revert to waiting so it
    # retries; on the <startup_fail_strikes>th (default 3), SURFACE it for a human instead.
    # Items that DID create a waypoint are owned by the resume-budget block below.
    if [[ -n "$_rb_id" ]]; then
      if [[ "$rc" -ne 0 && ! -f "$(_wp_json "$_rb_id")" ]]; then
        _spawnfail_bump "$_rb_id"
        local _sfs _cb_desc _cb_slug
        _sfs="$(_config_get startup_fail_strikes)"; _valid_positive_int "$_sfs" || _sfs=3
        # Both transitions target the EXACT claimed line ($running_line). A startup crash
        # leaves the item untouched, so this matches; if the worker somehow already moved
        # it, the exact-line match no-ops rather than touching the wrong/terminal item.
        if [[ "$(_spawnfail_count "$_rb_id")" -ge "$_sfs" ]]; then
          _cb_desc="${_rb_id_rest#*|}"; _cb_slug="$(_wp_slug "$_rb_id" "$_cb_desc")"
          printf 'startup-crash circuit-breaker: %s consecutive spawns died before any waypoint progress.\nSurfaced for a human — likely a broken spawn/env (the worker exits before `deputy start`).\nInvestigate the run log, fix the cause, then `deputy set "<line>" waiting` to retry.\n' "$_sfs" \
            > "$(_trail_path questions "$_cb_slug")" 2>/dev/null || true
          # Flip via the public cmd_set so the surface is committed + the human notified.
          cmd_set "$running_line" surfaced >/dev/null 2>&1 || true
          _spawnfail_reset "$_rb_id"
          printf 'deputy: startup-crash circuit-breaker tripped for #%s after %s no-progress spawns — surfaced.\n' "$_rb_id" "$_sfs" >&2
        else
          # under the limit: revert so the item is retried next tick (don't leave it orphaned running)
          _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
        fi
        _archive_run_log "$running_line" "$log"
        _active_run_release
        processed=$((processed + 1))
        [[ "$once" -eq 1 ]] && break
        [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
        continue
      else
        _spawnfail_reset "$_rb_id"   # progressed / clean exit / has a waypoint → reset the breaker
      fi
    fi
    # #97: runner merges a ready-merge branch when auto_merge=1 (only on a clean rc==0 exit).
    # On a successful merge the item is DONE — skip the retry-budget/failure handling below.
    if [[ "$rc" -eq 0 ]] && _auto_merge_ready "$running_line"; then
      _archive_run_log "$running_line" "$log"
      _active_run_release
      processed=$((processed + 1))
      [[ "$once" -eq 1 ]] && break
      [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
      continue
    fi
    # Successful orchestrator exit: track attempt progress.
    # If a new step was committed, the budget resets; otherwise increments attempt counter.
    if [[ -n "$_rb_id" ]]; then
      _wp_track_resume_attempt "$_rb_id"
      # Post-track: if budget is now exhausted (just hit threshold), mark failed.
      if _wp_retry_budget_exhausted "$_rb_id"; then
        local _rb_desc2; _rb_desc2="${_rb_id_rest#*|}"
        local _rb_slug2; _rb_slug2="$(_wp_slug "$_rb_id" "$_rb_desc2")"
        printf '%s\n' "cron resume budget exhausted ($_WP_RETRY_BUDGET attempts, no step progress)" \
          > "$(_trail_path fails "$_rb_slug2")"
        # Look up the current BACKLOG line for this item (running_line may still be in BACKLOG
        # if the orchestrator didn't mark the item terminal; search by id tag [#N]).
        local _rb_cur_line
        _rb_cur_line="$(_line_by_id "$_rb_id" || true)"
        [[ -n "$_rb_cur_line" ]] && { _with_lock _do_set_item_failed "$_rb_cur_line" || true; }
        _surface_blocked_by_failed "$_rb_id"   # #114: surface dependents of now-failed prereq
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

  # Unified arg grammar (tolerant of order): '#<id>' (canonical) or bare numeric =
  # one item by id; a bare '<state>' word (canonical, e.g. 'clean done') or the
  # '--state <s>'/'--state=<s>' alias = all items of that state (default waiting).
  # The '#' prefix and the pN/state shapes make a single positional unambiguous.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --state=*)   filter_state="${1#--state=}"; shift ;;
      --state)
        [[ $# -ge 2 ]] || { printf 'deputy: --state requires an argument\n' >&2; return 2; }
        filter_state="$2"; shift 2 ;;
      '#'*)
        filter_id="${1#'#'}"
        _valid_item_id "$filter_id" || { printf 'deputy: clean: invalid id: %s\n' "$1" >&2; return 2; }
        shift ;;
      *)
        if _valid_item_id "$1"; then
          filter_id="$1"; shift
        elif _valid_state "$1"; then
          filter_state="$1"; shift
        else
          printf 'deputy: clean: unexpected argument: %s (want <id> or a <state>)\n' "$1" >&2; return 2
        fi ;;
    esac
  done

  if [[ -n "$filter_id" ]]; then
    # ID-targeted clean: find and remove exactly one item by its ID (int or int.sub).
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
          running|triaging|surfaced|paused|pending-merge)
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
    running|triaging|surfaced|paused|pending-merge)
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
      _valid_item_id "$_dc_id" && rm -f "$STATE_DIR/proposed-$_dc_id" "$STATE_DIR/ready-merge-$_dc_id" 2>/dev/null || true
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
# The queue overview — learnings, untagged items, reprioritization review, potential
# duplicates, status digest (formerly 'deputy reflect', now folded into 'deputy watch').
# --apply writes the learnings snapshot. The actionable attention items (surfaced/failed/
# deferred) are shown separately by _attention_digest, so this omits a surfaced dump.
_queue_overview() {
  _with_lock _allocate_ids
  local apply=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --apply) apply=1; shift ;;
    *) printf 'deputy: watch: unexpected arg: %s\n' "$1" >&2; return 2 ;;
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

  printf '%s\n\n' "=== Deputy Queue Overview ==="

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

  # (Surfaced/failed/deferred attention items are shown by _attention_digest above.)

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
  local id="" waive=0
  id="${1:?done needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    # #113(D): an explicit, RECORDED waiver. The gate can be overridden — but never
    # silently: the waiver lands in the ledger so "done" always says which kind it was.
    --no-verify) waive=1; shift ;;
    *) printf 'deputy: done: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  _wp_require_jq || return 1
  _wp_validate_id "$id" || return 1

  # #113(D): outcome gate. `done` may only mean "the reported symptom is gone", so when
  # this task HAS an acceptance criterion, the green + bite verdicts must both be recorded
  # as passing. Tasks with NO acceptance record are unaffected (the gate is opt-in via the
  # record itself), so this can never block pre-existing or criterion-free work.
  local af obs; af="$(_accept_path "$id")"; obs=""
  [[ -f "$af" ]] && obs="$(_accept_field "$af" observe)"
  if [[ -n "$obs" && "$waive" -eq 0 ]]; then
    local vg vb; vg="$(_verify_verdict "$id" green)"; vb="$(_verify_verdict "$id" bite)"
    # A passing verdict taken on code that has since changed is not evidence about the
    # code being closed — re-verify rather than inherit it.
    [[ "$vg" == "pass" ]] && ! _verify_is_current "$id" green && vg="stale (code changed since it was taken)"
    [[ "$vb" == "pass" ]] && ! _verify_is_current "$id" bite  && vb="stale (code changed since it was taken)"
    if [[ "$vg" != "pass" || "$vb" != "pass" ]]; then
      printf 'deputy: done: REFUSED for %s — the reported symptom is not proven fixed.\n' "$id" >&2
      printf '  acceptance: %s\n' "$af" >&2
      printf '  green (symptom gone):        %s\n' "${vg:-not run}" >&2
      printf '  bite  (fix is load-bearing): %s\n' "${vb:-not run}" >&2
      printf '  run:  deputy verify %s --green && deputy verify %s --bite\n' "$id" "$id" >&2
      printf '  (steps committed + tests green + merged does NOT prove the symptom moved.\n' >&2
      printf '   override only with a reason you can defend: deputy done %s --no-verify)\n' "$id" >&2
      return 1
    fi
  fi
  # (E) When a smoke command is configured, a passing smoke run is part of done: unit
  # tests cannot see a bug that only exists against real data.
  if [[ -n "$(_config_get smoke_cmd)" && "$waive" -eq 0 ]]; then
    local vs; vs="$(_verify_verdict "$id" smoke)"
    [[ "$vs" == "pass" ]] && ! _verify_is_current "$id" smoke && vs="stale (code changed since it was taken)"
    if [[ "$vs" != "pass" ]]; then
      printf 'deputy: done: REFUSED for %s — smoke_cmd is configured but its verdict is "%s".\n' "$id" "${vs:-not run}" >&2
      printf '  run:  deputy verify %s --smoke   (or override: deputy done %s --no-verify)\n' "$id" "$id" >&2
      return 1
    fi
  fi

  _do_done() {
    # Guard (inside lock): all steps must be succeeded before marking the task done.
    if jq -e 'any(.steps[]; .status!="succeeded")' "$(_wp_json "$id")" >/dev/null; then
      printf 'deputy: done: not all steps succeeded for %s\n' "$id" >&2; return 1
    fi
    _wp_jq "$id" '.status="completed" | .current_step=null | .verify_waived=$w | .updated_at=$now' \
      --arg now "$(_wp_now)" --argjson w "$([[ "$waive" -eq 1 ]] && printf true || printf false)"
  }
  _with_lock _do_done || return 1
  # #113(F): empty steps are reported at done — N "implemented" steps that produced no
  # file changes is a plan that was wrong, and the reader should never have to diff to
  # discover that.
  local _n_empty _n_steps
  _n_empty="$(jq -r '[.steps[] | select(.empty == true)] | length' "$(_wp_json "$id")" 2>/dev/null || printf 0)"
  _n_steps="$(jq -r '.steps | length' "$(_wp_json "$id")" 2>/dev/null || printf 0)"
  [[ "${_n_empty:-0}" -gt 0 ]] && \
    printf 'deputy: note: %s of %s steps produced NO file changes (--allow-empty) for %s\n' "$_n_empty" "$_n_steps" "$id" >&2
  [[ "$waive" -eq 1 ]] && \
    printf 'deputy: note: %s marked done with the verification gate WAIVED (--no-verify)\n' "$id" >&2
  return 0
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
  # #113(F): an empty step commit is recorded as `empty:true`, never silently. A plan
  # whose steps mostly no-op looks like N implemented steps in the ledger while being
  # one commit plus filler — the reader must be able to see that.
  local _was_empty=false
  if git -C "$wt" diff --cached --quiet; then
    if [[ "$allow_empty" -ne 1 ]]; then
      printf 'deputy: commit: no changes staged in %s — a step must produce a committed change (use --allow-empty to override)\n' "$wt" >&2
      return 1
    fi
    _was_empty=true
    git -C "$wt" commit -q --allow-empty -m "${summary:-deputy step (no changes)}"
    printf 'deputy: warning: step committed with NO file changes (--allow-empty) — recorded as empty in the ledger\n' >&2
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
         (.status="succeeded" | .completed_at=$now | .empty=$empty
          | .actual_result={summary:$sum, artifacts:$arts})
       | .current_step=null | .updated_at=$now' \
      --arg sum "$summary" --arg now "$(_wp_now)" --argjson arts "$arts_json" \
      --argjson empty "$_was_empty"
  }
  _with_lock _do_commit
}

# Hidden helper for tests: print the raw waypoint.json.
cmd_wp_show() { cat "$(_wp_json "${1:?}")"; }

# ── #113: verification gates — prove the SYMPTOM moved, not just that code landed ────
# `deputy verify <id|slug> --<phase>` runs the acceptance record's `observe` command and
# records the outcome in waypoint.json under .verification.<phase>:
#   --red    BEFORE the fix — observe MUST FAIL. If it passes here, the check does not
#            capture the reported symptom (or the item is stale): stop, do not "fix" it.
#   --green  AFTER the fix — observe MUST PASS.
#   --bite   revert THIS branch's own commits in a scratch worktree and re-run observe —
#            it MUST FAIL again. This is the gate that catches a test written to fit the
#            diff: if the symptom stays fixed with the fix removed, nothing was proven.
#   --smoke  run config `smoke_cmd` against the real environment/data. Green unit tests
#            are not evidence when the bug only exists against live data.
# Exit: 0 pass (or a deliberately skipped gate), 1 the gate genuinely FAILED, 2 cannot run
# (no record / no observe / no smoke_cmd / bad usage), 3 INCONCLUSIVE — the check could not
# produce evidence (timed out, not found, or no clean reverted tree). 3 is deliberately
# distinct from 1: "the fix is wrong" and "we learned nothing" call for different responses.
_verify_timeout() { local t; t="$(_config_get verify_timeout_secs)"; [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] && printf '%s' "$t" || printf '300'; }

# Run <cmd> in <dir>, echo its exit status. ALWAYS bounded by verify_timeout_secs: an
# observe/smoke command comes from a config file or a human's acceptance record and may do
# anything, so a hung one must never wedge a headless worker. Where timeout(1) is missing we
# supervise by hand rather than running unbounded — the poll below is finite by construction
# and always reaps its child, so it cannot become an orphaned waiter.
_verify_run() { # <dir> <cmd> <logfile>
  local dir="$1" cmd="$2" log="$3" rc=0 t; t="$(_verify_timeout)"
  if command -v timeout >/dev/null 2>&1; then
    # No -k: uutils' timeout (0.2.x) returns 125 instead of 124 when --kill-after is given,
    # which would hide a real timeout behind "timeout itself failed". Plain timeout reports
    # 124 consistently across GNU and uutils, and 124..127 are all handled as non-evidence
    # by the caller anyway.
    ( cd "$dir" && timeout "$t" bash -c "$cmd" ) >"$log" 2>&1 || rc=$?
  else
    # Enable job control just long enough to background the check, so it lands in its OWN
    # process group (pgid == pid). Signalling the group rather than the pid alone is what
    # actually reaps a check that spawned children of its own (`foo & wait`), instead of
    # leaving them running against the repo after we have moved on.
    local _had_m=0; [[ "$-" == *m* ]] && _had_m=1
    set -m
    ( cd "$dir" && bash -c "$cmd" ) >"$log" 2>&1 &
    local pid=$! waited=0
    [[ "$_had_m" -eq 0 ]] && set +m
    while [[ "$waited" -lt "$t" ]] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124                                  # same signal as timeout(1)
    else
      wait "$pid" || rc=$?
    fi
  fi
  printf '%s' "$rc"
}

# Fingerprint of the item's committed work. A verdict is only evidence about the tree it
# was taken on: if further commits land afterwards, a recorded green/bite describes code
# that no longer exists. Stored with each verdict and re-checked at `done`.
_verify_fingerprint() { # <slug>
  local c; c="$(_verify_item_commits "$1" 2>/dev/null | tr '\n' ' ' || true)"
  _short_hash "${c:-none}"
}

# Record one phase's outcome, stamped with the fingerprint of the code it was taken on.
# Caller must NOT hold the lock (_with_lock is taken here).
_verify_record() { # <slug> <phase> <cmd> <rc> <verdict> <note>
  local slug="$1" ph="$2" cmd="$3" rc="$4" verdict="$5" note="$6" fp
  fp="$(_verify_fingerprint "$slug")"
  _do_vrec() {
    _wp_jq "$slug" \
      '.verification = ((.verification // {}) | .[$ph] = {cmd:$c, rc:($rc|tonumber), verdict:$v, note:$n, fp:$fp, at:$now})
       | .updated_at=$now' \
      --arg ph "$ph" --arg c "$cmd" --arg rc "$rc" --arg v "$verdict" --arg n "$note" \
      --arg fp "$fp" --arg now "$(_wp_now)"
  }
  _with_lock _do_vrec
}

# Read one field of a recorded verdict ("" when unrecorded).
_verify_field() { # <slug> <phase> <field>
  local f; f="$(_wp_json "$1")"
  [[ -f "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg ph "$2" --arg k "$3" '((.verification // {})[$ph] // {})[$k] // ""' "$f" 2>/dev/null
}
_verify_verdict() { _verify_field "$1" "$2" verdict; }

# A verdict counts as evidence only if it still describes the CURRENT code. Anything else
# is a verdict about a tree that no longer exists — which is the false positive this whole
# mechanism exists to stop, just with extra steps.
_verify_is_current() { # <slug> <phase>
  local fp; fp="$(_verify_field "$1" "$2" fp)"
  [[ -n "$fp" ]] || return 1                     # pre-fingerprint record → treat as stale
  [[ "$fp" == "$(_verify_fingerprint "$1")" ]]
}

# This item's OWN commits, newest-first, taken from the ledger's recorded step commits.
# The ledger is used in preference to a `merge-base(default, branch)..branch` range because
# that range collapses to empty the moment the branch is merged — which would make --bite
# permanently unavailable exactly when a human is reviewing an already-merged item.
# Emitted NEWEST-FIRST, which is the order `git revert` needs: reverting an older commit
# before a newer one that builds on it conflicts. The order comes from the ledger's step
# order (steps are appended oldest-first, so reversing them is exact) — NOT from
# `rev-list --no-walk=sorted`, which sorts by commit DATE and therefore returns an arbitrary
# order for two step commits made within the same second. That is rare enough to look like
# a flake and common enough to happen on any fast pair of steps.
_verify_item_commits() { # <slug>
  local f s; f="$(_wp_json "$1")"
  [[ -f "$f" ]] || return 1
  local -a raw=() ok=()
  mapfile -t raw < <(jq -r '.steps[]? | .actual_result?.artifacts[]?.step_commit // empty' "$f" 2>/dev/null || true)
  [[ "${#raw[@]}" -gt 0 ]] || return 1
  # Walk newest→oldest, keeping the first sighting of each SHA (one step can declare several
  # artifacts, all tagged with that step's single commit).
  local i seen=" "
  for (( i=${#raw[@]}-1; i>=0; i-- )); do
    s="${raw[$i]}"
    [[ -n "$s" && "$seen" != *" $s "* ]] || continue
    seen+="$s "
    git -C "$ROOT" rev-parse -q --verify "${s}^{commit}" >/dev/null 2>&1 && ok+=("$s")
  done
  [[ "${#ok[@]}" -gt 0 ]] || return 1
  printf '%s\n' "${ok[@]}"
}

# Build the scratch worktree for --bite: the current tree with THIS item's commits reverted.
# Reverting only the item's own commits (rather than checking out the pre-fix default branch)
# keeps everything else that landed meanwhile, so the single difference is the fix itself.
# Echoes the scratch path on success; rc1 = could not construct it (caller → inconclusive,
# never a pass — an unbuildable comparison must not be reported as evidence).
_verify_bite_tree() { # <slug> <outdir>
  local slug="$1" scratch="$2" branch="deputy/$slug" def base tip
  def="$(_default_branch)"; [[ -n "$def" ]] || return 1
  # Check out the branch tip when it still exists (pre-merge), else the default branch
  # (post-merge, or after delete_merged_branch cleaned the branch up).
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then tip="$branch"; else tip="$def"; fi
  local -a shas=()
  mapfile -t shas < <(_verify_item_commits "$slug" || true)
  if [[ "${#shas[@]}" -eq 0 ]]; then
    # No ledger commits (e.g. work done outside the spine): fall back to the branch range.
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || return 1
    base="$(git -C "$ROOT" merge-base "$def" "$branch" 2>/dev/null)" || return 1
    [[ -n "$base" ]] || return 1
    [[ "$(git -C "$ROOT" rev-list --count "$base..$branch" 2>/dev/null || printf 0)" -gt 0 ]] || return 1
    mapfile -t shas < <(git -C "$ROOT" rev-list "$base..$branch" 2>/dev/null)
    [[ "${#shas[@]}" -gt 0 ]] || return 1
  fi
  # Keep only commits actually contained in the tree we are about to check out; reverting a
  # commit that is not in this history would fail or revert something unrelated.
  local -a use=(); local s
  for s in "${shas[@]}"; do
    [[ -n "$s" ]] || continue
    git -C "$ROOT" merge-base --is-ancestor "$s" "$tip" 2>/dev/null && use+=("$s")
  done
  [[ "${#use[@]}" -gt 0 ]] || return 1
  git -C "$ROOT" worktree prune 2>/dev/null || true
  # The scratch path is PID-unique: a fixed name would let two concurrent --bite runs
  # force-remove each other's tree mid-check (a human verifying while a worker verifies).
  [[ -e "$scratch" ]] && _verify_drop_scratch "$scratch"
  git -C "$ROOT" worktree add --detach "$scratch" "$tip" >/dev/null 2>&1 || return 1
  # -n applies every revert to the index/worktree without committing. A conflict here means
  # we cannot construct a clean "without the fix" tree → inconclusive, never a pass.
  if ! git -C "$scratch" revert -n "${use[@]}" >/dev/null 2>&1; then
    git -C "$scratch" revert --abort >/dev/null 2>&1 || true
    _verify_drop_scratch "$scratch"
    return 1
  fi
  printf '%s' "$scratch"
}

# Remove a --bite scratch worktree and deregister it. Also sweeps scratch dirs abandoned by
# a dead run, so a killed verify can't leave worktrees accumulating under .deputy/.
_verify_drop_scratch() { # [<path>]
  local p
  [[ -n "${1:-}" && -e "$1" ]] && git -C "$ROOT" worktree remove --force "$1" >/dev/null 2>&1
  [[ -n "${1:-}" && -e "$1" ]] && rm -rf -- "$1" 2>/dev/null || true
  shopt -s nullglob
  for p in "$STATE_DIR"/verify-wt.*; do
    [[ "$p" == "${1:-}" ]] && continue
    # Only reclaim another run's scratch when that pid is gone.
    local _vp="${p##*verify-wt.}"
    [[ "$_vp" =~ ^[0-9]+$ ]] && kill -0 "$_vp" 2>/dev/null && continue
    git -C "$ROOT" worktree remove --force "$p" >/dev/null 2>&1 || rm -rf -- "$p" 2>/dev/null || true
  done
  shopt -u nullglob
  git -C "$ROOT" worktree prune 2>/dev/null || true
}

cmd_verify() {
  local a="${1:-}" phase=""
  [[ -n "$a" ]] || { printf 'deputy: verify requires an <id|slug> and a phase (--red|--green|--bite|--smoke|--status)\n' >&2; return 2; }
  shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --red|--green|--bite|--smoke|--status) phase="${1#--}"; shift ;;
    *) printf 'deputy: verify: unexpected arg: %s (want --red|--green|--bite|--smoke|--status)\n' "$1" >&2; return 2 ;;
  esac; done
  [[ -n "$phase" ]] || { printf 'deputy: verify needs a phase: --red|--green|--bite|--smoke|--status\n' >&2; return 2; }
  _wp_require_jq || return 2
  local slug; slug="$(_accept_slug_of "$a")"
  [[ -n "$slug" ]] || { printf 'deputy: verify: no task %s\n' "$a" >&2; return 2; }
  _wp_validate_id "$slug" || return 2
  [[ -f "$(_wp_json "$slug")" ]] || { printf 'deputy: verify: no waypoint ledger for %s (run: deputy start %s "<goal>")\n' "$slug" "$slug" >&2; return 2; }

  if [[ "$phase" == "status" ]]; then
    jq -r '(.verification // {}) | to_entries | if length==0 then "no verification recorded"
           else (.[] | "\(.key): \(.value.verdict)  (rc=\(.value.rc)) \(.value.note // "")") end' \
      "$(_wp_json "$slug")"
    return 0
  fi

  local wt cmd dir rc verdict note="" log
  wt="$(_wt_path)"
  log="$(mktemp)"

  if [[ "$phase" == "smoke" ]]; then
    cmd="$(_config_get smoke_cmd)"
    [[ -n "$cmd" ]] || { printf 'deputy: verify --smoke: no smoke_cmd configured (deputy config smoke_cmd "<command>")\n' >&2; rm -f "$log"; return 2; }
  else
    local af; af="$(_accept_path "$slug")"
    [[ -f "$af" ]] || { printf 'deputy: verify: no acceptance record for %s — nothing to verify against.\n  add one: deputy accept %s --observe "<how to see it>" ...\n' "$slug" "${a#\#}" >&2; rm -f "$log"; return 2; }
    cmd="$(_accept_field "$af" observe)"
    [[ -n "$cmd" ]] || { printf 'deputy: verify: acceptance record for %s has no `observe` command — nothing to run.\n' "$slug" >&2; rm -f "$log"; return 2; }
  fi

  # The red gate only means anything BEFORE the first fix commit. On a RESUMED run the work
  # is already committed, so `observe` is expected to pass — treating that as "the check is
  # wrong" would surface every resumed item. Skip rather than judge.
  if [[ "$phase" == "red" ]] && _verify_item_commits "$slug" >/dev/null 2>&1; then
    printf 'deputy: verify --red: SKIPPED for %s — the item already has committed work, so the\n' "$slug"
    printf '  pre-fix state no longer exists here. The red gate applies only before the first\n'
    printf '  commit; on a resumed run go straight to --green/--bite.\n'
    rm -f "$log"; return 0
  fi

  if [[ "$phase" == "bite" ]]; then
    local scratch="$STATE_DIR/verify-wt.$$"
    if ! dir="$(_verify_bite_tree "$slug" "$scratch")"; then
      _verify_record "$slug" bite "$cmd" 0 inconclusive "could not build a reverted tree (no commits on deputy/$slug, or the revert conflicts) — verify by hand"
      printf 'deputy: verify --bite: INCONCLUSIVE for %s — could not construct a clean "without the fix" tree.\n' "$slug" >&2
      rm -f "$log"; return 3
    fi
    rc="$(_verify_run "$dir" "$cmd" "$log")"
    _verify_drop_scratch "$scratch"
  else
    dir="$wt"; [[ -d "$dir" ]] || dir="$ROOT"
    rc="$(_verify_run "$dir" "$cmd" "$log")"
  fi

  # A check that could not RUN proves nothing in either direction. This matters most for
  # red/bite, which read "observe failed" as evidence the symptom is present: without this,
  # a check that hung (124), or was mistyped so the shell never found it (127), would count
  # as proof the bug is real — the exact false positive this command exists to prevent,
  # inverted. 124 timed out, 125 timeout(1) itself failed, 126 not executable, 127 not found.
  if [[ "$rc" -ge 124 && "$rc" -le 127 ]]; then
    local why
    case "$rc" in
      124|125) why="timed out after $(_verify_timeout)s" ;;
      126)     why="the command is not executable" ;;
      *)       why="the command was not found" ;;
    esac
    _verify_record "$slug" "$phase" "$cmd" "$rc" inconclusive "$why"
    printf 'deputy: verify --%s: INCONCLUSIVE for %s — `%s`: %s (rc=%s).\n' "$phase" "$slug" "$cmd" "$why" "$rc" >&2
    printf '  A check that could not run is not evidence. Fix the check%s.\n' \
      "$([[ "$rc" -le 125 ]] && printf ', or raise: deputy config verify_timeout_secs <n>')" >&2
    printf -- '--- last 20 lines of output ---\n' >&2
    tail -20 "$log" >&2 2>/dev/null || true
    rm -f "$log"; return 3
  fi
  # red and bite both assert the symptom is PRESENT (observe fails); green and smoke
  # assert it is GONE (observe passes).
  case "$phase" in
    red|bite) [[ "$rc" -ne 0 ]] && verdict=pass || verdict=fail ;;
    *)        [[ "$rc" -eq 0 ]] && verdict=pass || verdict=fail ;;
  esac
  # A nonzero exit only says "something failed" — not that it failed the REPORTED way. When
  # the record carries a `match` regex, require the failure to look like the reported one, so
  # a blank column that has become a thrown exception is not scored as the same symptom.
  if [[ "$verdict" == "pass" && ( "$phase" == "red" || "$phase" == "bite" ) ]]; then
    local _mre; _mre="$(_accept_field "$(_accept_path "$slug")" match 2>/dev/null || true)"
    if [[ -n "$_mre" ]] && ! grep -Eq -- "$_mre" "$log" 2>/dev/null; then
      verdict=fail
      note="output does not match the reported failure /$_mre/"
      _verify_record "$slug" "$phase" "$cmd" "$rc" "$verdict" "$note"
      printf 'deputy: verify --%s FAIL — `%s` failed (rc=%s), but NOT in the reported way:\n' "$phase" "$cmd" "$rc" >&2
      printf '  its output does not match /%s/. A different failure is not the same bug.\n' "$_mre" >&2
      printf -- '--- last 20 lines of output ---\n' >&2
      tail -20 "$log" >&2 2>/dev/null || true
      rm -f "$log"; return 1
    fi
  fi
  _verify_record "$slug" "$phase" "$cmd" "$rc" "$verdict" "$note"

  if [[ "$verdict" == "pass" ]]; then
    case "$phase" in
      red)   printf 'deputy: verify --red PASS — the symptom reproduces (rc=%s). Proceed with the fix.\n' "$rc" ;;
      green) printf 'deputy: verify --green PASS — the symptom is gone (rc=0).\n' ;;
      bite)  printf 'deputy: verify --bite PASS — the symptom returns with the fix reverted (rc=%s); the fix is load-bearing.\n' "$rc" ;;
      smoke) printf 'deputy: verify --smoke PASS — smoke_cmd succeeded against the real environment.\n' ;;
    esac
    rm -f "$log"; return 0
  fi
  case "$phase" in
    red)   printf 'deputy: verify --red FAIL — `%s` already SUCCEEDS before any fix.\n  The check does not capture the reported symptom, or the item is stale. Do NOT proceed: surface it.\n' "$cmd" >&2 ;;
    green) printf 'deputy: verify --green FAIL — `%s` still fails (rc=%s). The reported symptom is NOT fixed.\n' "$cmd" "$rc" >&2 ;;
    bite)  printf 'deputy: verify --bite FAIL — `%s` still passes with the fix reverted.\n  The check does not bite: it proves nothing about this fix. Fix the check, not the code.\n' "$cmd" >&2 ;;
    smoke) printf 'deputy: verify --smoke FAIL — smoke_cmd failed (rc=%s) against the real environment.\n' "$rc" >&2 ;;
  esac
  printf -- '--- last 20 lines of output ---\n' >&2
  tail -20 "$log" >&2 2>/dev/null || true
  rm -f "$log"
  return 1
}

# ── Retry budget helpers ─────────────────────────────────────────────────────
# Budget: if an item has been cron-resumed _WP_RETRY_BUDGET times with no new committed step,
# stop reviving it (mark it failed). Stored in waypoint.json as `resume_attempts`
# (an integer; absent = 0) and `resume_attempts_committed_steps` (count of
# succeeded steps at the last attempt; if step count grew → reset budget).
#
# The budget only applies when a waypoint exists for the item.
# Items without a waypoint (no waypoints/ dir) are not budgeted.

# Maximum no-progress resumes before marking the item failed.
# Kept >= the per-step xReview retry budget in SKILL.md §4 (initial try + 3 retries):
# extra review rounds inside one step commit no new step, so a too-small resume budget
# would kill a worker before its last allowed retry ever runs.
_WP_RETRY_BUDGET=4

# Convert item id + description to a safe filesystem slug for .fail.md filenames.
_wp_slug() {
  local id="$1" desc="$2"
  local slug="${id}-${desc}"
  # Replace non-alphanumeric characters with dashes; collapse consecutive dashes; trim.
  slug="$(printf '%s' "$slug" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s' "${slug:0:64}"
}

# --- #99: deterministic, idempotent per-task branch/slug -------------------------------
# The slug (→ branch deputy/<slug> → worktree) is FROZEN at add time from the IMMUTABLE
# user-input description, so every resume/rerun of a task lands on the SAME branch. This
# replaces the old model where the LLM orchestrator re-derived a slug from a (mutable,
# possibly-refined) description each run — which produced drift and duplicate branches
# (e.g. #96's cron-set-heartbeat-96 vs deputy-cron-set-heartbeat-96).

# Short, stable content fingerprint (8 hex). Dependency-light: sha256sum, else shasum,
# else cksum (weaker, but always present). Deterministic for a given input string.
_short_hash() {
  local s="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | cut -c1-8
  else
    printf '%s' "$s" | cksum | awk '{printf "%08x", $1}' | cut -c1-8
  fi
}

# Canonical slug for a task: <id>-<hash8>-<descslug>. Derived ONLY from (id, user_desc);
# same inputs → same slug forever, independent of any later description refinement.
_canonical_slug() {
  local id="$1" user_desc="$2" h ds
  h="$(_short_hash "$user_desc")"
  ds="$(printf '%s' "$user_desc" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  ds="${ds:0:40}"; ds="${ds%-}"     # cap the readable part; never end on a dash
  printf '%s-%s-%s' "$id" "$h" "$ds"
}

_meta_dir()  { printf '%s' "$STATE_DIR/meta"; }
_meta_path() { printf '%s/%s.meta' "$(_meta_dir)" "$1"; }
# Read one `key: value` field from a task's meta file (empty + rc1 if absent).
_meta_get() {
  local f; f="$(_meta_path "$1")"
  [[ -f "$f" ]] || return 1
  sed -n "s/^$2: //p" "$f" 2>/dev/null | head -1
}
# Write a task's meta ONCE (immutable): the original user description + the frozen slug.
# Never overwrites existing meta — the user_desc/slug must stay stable for the task's life.
# Atomic (temp + rename) and status-returning: rc0 = written or already present; rc1 = could
# NOT persist. `add` treats rc1 as fatal (a task must never exist without its frozen slug);
# the backfill path treats it as best-effort (cmd_slug still derives a deterministic slug).
_write_task_meta() {  # <id> <user_desc>
  local id="$1" ud="$2" f md tmp
  _valid_item_id "$id" || return 1
  md="$(_meta_dir)"; mkdir -p "$md" 2>/dev/null || return 1
  f="$(_meta_path "$id")"
  if [[ -f "$f" ]]; then
    # Existing meta with the SAME user_desc → already frozen, keep it (immutable). A DIFFERENT
    # user_desc can only be a stale orphan: callers always pass a fresh _next_id (or backfill a
    # live item that had no meta), so no live task shares this id — the orphan is from an add
    # interrupted between meta-rename and append. Fall through to overwrite it.
    local _existing; _existing="$(sed -n 's/^user_desc: //p' "$f" 2>/dev/null | head -1)"
    [[ "$_existing" == "$ud" ]] && return 0
  fi
  tmp="$f.tmp.$$"
  { printf 'user_desc: %s\n' "$ud"
    printf 'slug: %s\n' "$(_canonical_slug "$id" "$ud")"
    printf 'created-at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# `deputy slug <id>` — print the task's canonical (frozen) slug. Single source of truth for
# the orchestrator, wt-create, resume, and the runner: never invent a slug, always ask this.
# Legacy items (added before meta existed) are backfilled from their current description and
# frozen on first call, so they too become stable from then on.
cmd_slug() {
  local id="$1"
  [[ -n "$id" ]] || { printf 'deputy: slug requires an <id>\n' >&2; return 2; }
  id="${id#\#}"
  _valid_item_id "$id" || { printf 'deputy: slug: invalid id: %s\n' "$id" >&2; return 2; }
  local s; s="$(_meta_get "$id" slug || true)"
  if [[ -n "$s" ]]; then printf '%s\n' "$s"; return 0; fi
  # Backfill: freeze from the current BACKLOG description (best available user_desc). Anchor the
  # id tag to the line start (after an optional 1-char status prefix) so a description that merely
  # mentions "[#<id>]" can't hijack the match — the id tag always leads the line. Escape the id's
  # '.' (a sub-id like 145.2) so the ERE doesn't treat it as a wildcard (_id_re).
  local line pi desc
  line="$(grep -E "^[^[]?\[#$(_id_re "$id")\]" "$BACKLOG" 2>/dev/null | head -1 || true)"
  [[ -n "$line" ]] || { printf 'deputy: slug: no task #%s found\n' "$id" >&2; return 1; }
  pi="$(_parse_item "$line")"; desc="${pi#*|}"; desc="${desc#*|}"; desc="${desc#*|}"
  _write_task_meta "$id" "$desc"
  s="$(_meta_get "$id" slug || true)"
  [[ -n "$s" ]] && { printf '%s\n' "$s"; return 0; }
  # Meta unwritable (e.g. read-only .deputy): still return a deterministic slug so callers work.
  _canonical_slug "$id" "$desc"; printf '\n'
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
  local _dsif_prereq; _dsif_prereq="$(_prereq_ids_from_line "$raw")"
  to="$(_serialize_item failed "$prio" "$_fsid" "$desc" "$_dsif_prereq")"
  _flip_line "$raw" "$to"
}

# #114: surface waiting/paused items that depend on a now-failed prerequisite.
# 'failed' is NOT a satisfying terminal state, so any dependent whose only path through
# the prereq graph goes through a failed node can never become runnable. Surfacing it
# makes the chain-stuck condition visible instead of letting watch report quiescence.
# Called OUTSIDE any lock (uses cmd_set which acquires its own lock per item).
_surface_blocked_by_failed() {
  local failed_id="$1" raw parsed state dep_id dep_desc dep_prio dep_slug qf
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    [[ "$state" == "waiting" || "$state" == "paused" ]] || continue
    local dep_prereqs; dep_prereqs="$(_prereq_ids_from_line "$raw")"
    [[ -z "$dep_prereqs" ]] && continue
    # Check whether this item lists the failed ID as one of its prereqs.
    local _sbf_found=0 _sbf_prid
    while IFS= read -r _sbf_prid; do
      [[ -z "$_sbf_prid" ]] && continue
      [[ "$_sbf_prid" == "$failed_id" ]] && { _sbf_found=1; break; }
    done <<< "${dep_prereqs//,/$'\n'}"
    [[ "$_sbf_found" -eq 0 ]] && continue
    dep_id="${parsed#*|}"; dep_id="${dep_id#*|}"; dep_id="${dep_id%%|*}"
    dep_prio="${parsed#*|}"; dep_prio="${dep_prio%%|*}"
    dep_desc="${parsed#*|}"; dep_desc="${dep_desc#*|}"; dep_desc="${dep_desc#*|}"
    dep_slug="$(_wp_slug "$dep_id" "$dep_desc")" 2>/dev/null || true
    qf="$(_trail_path questions "$dep_slug")" 2>/dev/null || true
    printf 'Prerequisite #%s has failed — this item can never become runnable.\nResolve by cancelling this item, fixing and retrying the failed prerequisite, or removing the failed prereq from BACKLOG.md.\n' \
      "$failed_id" >> "$qf" 2>/dev/null || true
    cmd_set "$raw" surfaced >/dev/null 2>&1 || true
  done < <(_each_item)
}

# #67 startup-crash circuit-breaker counters: consecutive FAILED spawns that never
# created a waypoint ledger (the resume-budget can't see those). Per-item dotfile counter.
_spawnfail_count() { local c; c="$(cat "$STATE_DIR/.spawnfail-$1" 2>/dev/null || true)"; [[ "$c" =~ ^[0-9]+$ ]] && printf '%s' "$c" || printf '0'; }
_spawnfail_bump()  { local n; n=$(( $(_spawnfail_count "$1") + 1 )); printf '%s\n' "$n" > "$STATE_DIR/.spawnfail-$1" 2>/dev/null || true; }
_spawnfail_reset() { rm -f "$STATE_DIR/.spawnfail-$1" 2>/dev/null || true; }

# #112: per-item CONSECUTIVE merge-failure counter for a parked (pending-merge) item.
# A merge blocked by the human's tree is transient, so the runner keeps retrying it — but a
# merge that stays blocked forever must not sit invisible, so after merge_retry_strikes
# consecutive failures the item escalates to 'surfaced'. Line 1 is the count; line 2 is the
# most recent blocker text, shown in the item's detail block.
_mergefail_count()  { local n; n="$(sed -n '1p' "$STATE_DIR/.mergefail-$1" 2>/dev/null || true)"
                      [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'; }
_mergefail_reason() { sed -n '2p' "$STATE_DIR/.mergefail-$1" 2>/dev/null || true; }
_mergefail_bump()   { local n; n=$(( $(_mergefail_count "$1") + 1 ))
                      { printf '%s\n' "$n"; printf '%s\n' "${2:-}"; } > "$STATE_DIR/.mergefail-$1" 2>/dev/null || true
                      printf '%s' "$n"; }
_mergefail_reset()  { rm -f "$STATE_DIR/.mergefail-$1" 2>/dev/null || true; }

# Count waiting+paused items (the runnable set cmd_pick draws from).
# ── Attention-item detail (shared by list / watch / pickup) ───────────────────
# Locate a task's questions file across the #70 subfolder layout AND the legacy flat layout,
# matching BOTH slug conventions (<desc>-<id> suffix and <id>-<desc> prefix). First match wins.
_questions_file() {
  local id="$1" cand
  _valid_item_id "$id" || return 1
  for cand in "$STATE_DIR"/questions/*-"$id".md "$STATE_DIR"/questions/"$id"-*.md \
              "$STATE_DIR"/*-"$id".questions.md "$STATE_DIR"/"$id"-*.questions.md; do
    [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}
# Same, for a task's failure-context (.fail.md) file.
_fail_file() {
  local id="$1" cand
  _valid_item_id "$id" || return 1
  for cand in "$STATE_DIR"/fails/*-"$id".md "$STATE_DIR"/fails/"$id"-*.md \
              "$STATE_DIR"/*-"$id".fail.md "$STATE_DIR"/"$id"-*.fail.md; do
    [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}
# Resolve the deputy/<slug> branch for a ready-merge item — mirrors _auto_merge_ready's
# resolution so what 'list'/'pickup' show matches what the runner would merge: (1) the branch
# recorded in the marker (#98); (2) the deterministic canonical branch (#99) if it exists;
# (3) a UNIQUE legacy deputy/*-<id> branch. Empty if none / ambiguous.
_ready_merge_branch() {
  local id="$1" br cands n
  br="$(sed -n 's/^branch: //p' "$STATE_DIR/ready-merge-$id" 2>/dev/null | head -1)"
  [[ "$br" == deputy/* ]] && { printf '%s' "$br"; return 0; }
  br="deputy/$(cmd_slug "$id" 2>/dev/null || true)"
  [[ "$br" != "deputy/" && "$br" == deputy/* ]] && git -C "$ROOT" show-ref --verify --quiet "refs/heads/$br" 2>/dev/null \
    && { printf '%s' "$br"; return 0; }
  cands="$(git -C "$ROOT" branch --list "deputy/*-$id" --format='%(refname:short)' 2>/dev/null)"
  n="$(printf '%s\n' "$cands" | grep -c .)"
  [[ "$n" -eq 1 ]] && { printf '%s' "$cands"; return 0; }
  return 1
}
# Classify a surfaced item by its marker: needs-input (default), ready-to-merge, or proposed.
_surfaced_kind() {
  local id="$1" kind="needs input"
  if _valid_item_id "$id"; then
    [[ -f "$STATE_DIR/ready-merge-$id" ]] && kind="ready to merge"
    [[ -f "$STATE_DIR/proposed-$id"    ]] && kind="proposed"
  fi
  printf '%s' "$kind"
}
# Print the indented per-task detail block for an ATTENTION item (surfaced / failed /
# deferred / paused / cancelled). Shared by 'list', 'watch', and 'pickup' so the shown detail
# and the suggested command never drift. Prints nothing for non-attention states. Lines are
# indented, so a leading serialized item line stays greppable above this block.
_item_detail_block() {
  local state="$1" id="$2" kind qf ff first slug def
  case "$state" in
    surfaced)
      kind="$(_surfaced_kind "$id")"
      printf '      status:  %s\n' "$kind"
      if qf="$(_questions_file "$id")"; then
        printf '      details: %s\n' "$qf"
        first="$(head -1 "$qf" 2>/dev/null || true)"
        [[ -n "$first" ]] && printf '      summary: %s\n' "$first"
      fi
      case "$kind" in
        "ready to merge")
          slug="$(_ready_merge_branch "$id" || true)"
          def="$(_default_branch)"; def="${def:-<default-branch>}"
          printf '      action:  deputy pickup %s   (merges %s into %s)\n' "$id" "${slug:-deputy/<slug>}" "$def" ;;
        "proposed")
          printf '      action:  deputy pickup %s   (approve → waiting; or deputy set %s cancelled to reject)\n' "$id" "$id" ;;
        *)
          printf '      action:  deputy pickup %s   (resume via /deputy from its waypoint)\n' "$id" ;;
      esac ;;
    failed)
      if ff="$(_fail_file "$id")"; then
        printf '      details: %s\n' "$ff"
        first="$(head -1 "$ff" 2>/dev/null || true)"
        [[ -n "$first" ]] && printf '      reason:  %s\n' "$first"
      fi
      printf '      action:  deputy pickup %s   (requeue → waiting)\n' "$id" ;;
    deferred|paused|cancelled)
      printf '      action:  deputy pickup %s   (revive → waiting)\n' "$id" ;;
    pending-merge)
      # #112: informational ONLY — deputy owns this merge. The human is never asked to act;
      # the runner retries it at the top of each tick until it lands (or, after
      # merge_retry_strikes consecutive failures, escalates it to surfaced).
      local br strikes cap
      br="$(_ready_merge_branch "$id" 2>/dev/null || true)"
      strikes="$(_mergefail_count "$id")"
      cap="$(_config_get merge_retry_strikes)"; _valid_positive_int "$cap" || cap=10
      printf '      status:  waiting to merge%s\n' "${br:+ ($br)}"
      first="$(_mergefail_reason "$id")"
      [[ -n "$first" ]] && printf '      blocker: %s\n' "$first"
      printf '      retries: %s of %s before this is surfaced for you\n' "$strikes" "$cap"
      printf '      action:  none — deputy merges this automatically on a later run\n' ;;
  esac
}

_runnable_count() {
  local n=0 raw parsed state
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting|paused)
        # #114: blocked items (unmet prereqs) are NOT runnable — exclude them so
        # deputy watch reaches quiescence even when blocked items are present.
        _prereqs_satisfied_for_line "$raw" || continue
        n=$(( n + 1 )) ;;
    esac
  done < <(_each_item)
  printf '%s' "$n"
}

# Count ALL surfaced items — needs-input (blocked), ready-to-merge, AND proposals.
# Every surfaced item awaits some human action (answer / review+merge / approve-reject),
# so the watch summon fires for any of them. (This is intentionally broader than
# _blocking_surfaced_count, which excludes ready-merge/proposals for the *scheduling*
# guard — a different concern.)
_surfaced_count() {
  local n=0 raw parsed state
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    [[ "$state" == surfaced ]] && n=$(( n + 1 ))
  done < <(_each_item)
  printf '%s' "$n"
}

# Emit 3 terminal BEL chars ~0.3 s apart. No-op when stdout is not a TTY.
_watch_beep() {
  [[ -t 1 ]] || return 0
  printf '\a'; sleep 0.3; printf '\a'; sleep 0.3; printf '\a'
}

# States that warrant a human's attention — what 'deputy watch' monitors and summons for.
_ATTENTION_STATES="surfaced failed deferred"
# Count items in any attention state (surfaced/failed/deferred).
_attention_count() {
  local n=0 raw parsed state
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case " $_ATTENTION_STATES " in *" $state "*) n=$(( n + 1 )) ;; esac
  done < <(_each_item)
  printf '%s' "$n"
}

# Print the attention digest: every surfaced/failed/deferred item, each followed by the shared
# detail block (status/details/summary/action → 'deputy pickup #<id>'). This is what the watch
# quiescence summon prints; the header names the trigger.
_attention_digest() {
  local raw p state rest prio id desc any=0
  printf '\ndeputy: batch quiescent — these items need your attention:\n'
  while IFS= read -r raw; do
    p="$(_parse_item "$raw")"; state="${p%%|*}"
    case " $_ATTENTION_STATES " in *" $state "*) ;; *) continue ;; esac
    rest="${p#*|}"; prio="${rest%%|*}"; rest="${rest#*|}"; id="${rest%%|*}"; desc="${rest#*|}"
    any=1
    printf '\n  #%s [%s] %s  — %s\n' "${id:-?}" "${prio:-?}" "$desc" "$state"
    _item_detail_block "$state" "$id"
  done < <(_each_item)
  [[ "$any" -eq 0 ]] && printf '  (no attention items found)\n'
  printf '\n'
}

# #63/#79: the one "what needs me" command. Prints the queue OVERVIEW once (learnings,
# untagged, reprioritization review, duplicates, status — formerly 'deputy reflect'), then runs
# as a passive, persistent monitor. Per poll tick:
#   worker live  → live-tail it (existing path); loop back after tail exits and re-arm.
#   runnable > 0 → stay quiet, keep polling (work still queued; NOT quiescent yet).
#   quiescent    → runnable==0 AND an attention item exists (surfaced / failed / deferred):
#                  beep 3× + print the attention digest ONCE; re-arms after the next run.
#   empty        → no worker, no attention, no runnable: friendly one-shot exit.
# --once: print overview + one poll pass, then exit (test/script seam; live-tail still blocks
# until the run ends). --apply: print overview + write the learnings snapshot, then exit.
# Ctrl-C exits; the 'tail' alias is preserved.
# ── #108: passive, read-only task-progress view ──────────────────────────────
# Portable ISO-8601 → epoch seconds. GNU `date -d` handles Z/±HH:MM/fractional
# directly; the BSD/macOS fallback normalizes first (strip fractional + tz, which
# `${iso%%.*}` already drops when a fraction is present) then parses naive wall
# time as a best-effort. Prints epoch secs; empty + rc1 if unparseable — every
# caller guards against an empty result.
_iso_epoch() {
  local iso="${1:-}"; [[ -n "$iso" ]] || return 1
  local e
  if e="$(date -d "$iso" +%s 2>/dev/null)" && [[ -n "$e" ]]; then printf '%s' "$e"; return 0; fi
  local norm="${iso%%.*}"                                  # drop fractional (+ any trailing tz)
  norm="${norm%Z}"; norm="${norm%[+-][0-9][0-9]:[0-9][0-9]}"   # drop a bare Z / ±HH:MM offset
  if e="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$norm" +%s 2>/dev/null)" && [[ -n "$e" ]]; then printf '%s' "$e"; return 0; fi
  return 1
}

# Human-readable elapsed since an epoch (e.g. '3m ago'); 'unknown' if empty/bad.
_ago_human() {
  local t="${1:-}"; [[ -n "$t" ]] || { printf 'unknown'; return; }
  local now d; now="$(date +%s)"; d=$(( now - t )); (( d < 0 )) && d=0
  if   (( d < 60 ));    then printf '%ds ago' "$d"
  elif (( d < 3600 ));  then printf '%dm ago' "$(( d/60 ))"
  elif (( d < 86400 )); then printf '%dh %dm ago' "$(( d/3600 ))" "$(( (d%3600)/60 ))"
  else printf '%dd %dh ago' "$(( d/86400 ))" "$(( (d%86400)/3600 ))"; fi
}

# Compact duration for a span of seconds (e.g. '5m', '2h10m').
_dur_human() {
  local s="${1:-0}"
  (( s < 60 ))    && { printf '%ds' "$s"; return; }
  (( s < 3600 ))  && { printf '%dm' "$(( s/60 ))"; return; }
  (( s < 86400 )) && { printf '%dh%dm' "$(( s/3600 ))" "$(( (s%3600)/60 ))"; return; }
  printf '%dd%dh' "$(( s/86400 ))" "$(( (s%86400)/3600 ))"
}

# Median per-step duration (secs) across PAST completed ledgers, EXCLUDING the
# current slug. A step's duration = completed_at − (previous succeeded step's
# completed_at, or the ledger's created_at for the first). Only positive,
# parseable durations count. Prints the median integer secs, empty if no history.
_progress_median_step_secs() {
  local cur="$1" wdir="$STATE_DIR/waypoints" j slug
  [[ -d "$wdir" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local -a durs=()
  for j in "$wdir"/*/waypoint.json; do
    [[ -f "$j" ]] || continue
    slug="$(basename "$(dirname "$j")")"
    [[ "$slug" == "$cur" ]] && continue
    # Only COMPLETED ledgers count as history — a partial/live run would skew the median.
    jq -e '.status=="completed"' "$j" >/dev/null 2>&1 || continue
    local created prev cline ce dur
    created="$(jq -r '.created_at // empty' "$j" 2>/dev/null)"
    [[ -n "$created" ]] || continue
    prev="$(_iso_epoch "$created")"; [[ -n "$prev" ]] || continue
    while IFS= read -r cline; do
      [[ -n "$cline" ]] || continue
      ce="$(_iso_epoch "$cline")"; [[ -n "$ce" ]] || continue
      dur=$(( ce - prev )); (( dur > 0 )) && durs+=( "$dur" )
      prev="$ce"
    done < <(jq -r '.steps[] | select(.status=="succeeded" and (.completed_at // "") != "") | .completed_at' "$j" 2>/dev/null)
  done
  (( ${#durs[@]} > 0 )) || return 1
  printf '%s\n' "${durs[@]}" | sort -n | \
    awk '{a[NR]=$1} END{ n=NR; if(n%2) print a[(n+1)/2]; else print int((a[n/2]+a[n/2+1])/2) }'
}

# Tier 2: print an ETA BAND for the remaining steps (never a crisp number).
_progress_eta() {
  local content="$1" slug="$2" n="$3" succ="$4" current="$5" status="$6"
  local remaining=$(( n - succ )); (( remaining < 0 )) && remaining=0
  if [[ "$n" -eq 0 || "$remaining" -eq 0 ]]; then
    if [[ "$status" == "completed" ]]; then printf 'ETA: — (no remaining steps)\n'
    else printf 'ETA: unknown (all planned steps done; finalizing or re-planning)\n'; fi
    return 0
  fi
  local median; median="$(_progress_median_step_secs "$slug" || true)"
  if [[ -z "$median" || "$median" -le 0 ]]; then
    printf 'ETA: unknown (insufficient completed-step history)\n'; return 0
  fi
  # Active elapsed on the in_progress step: now − (last succeeded completed_at, or
  # ledger created_at). Best-effort; subtracted from the band center, floored at 0.
  local active=0
  if [[ -n "$current" ]]; then
    local ref refe now
    ref="$(jq -r 'if ([.steps[]|select(.status=="succeeded")]|length) > 0
                   then ([.steps[]|select(.status=="succeeded")]|last|.completed_at)
                   else .created_at end // ""' <<<"$content")"
    refe="$(_iso_epoch "$ref" || true)"; now="$(date +%s)"
    [[ -n "$refe" ]] && active=$(( now - refe )); (( active < 0 )) && active=0
  fi
  local center=$(( remaining * median - active ))
  if (( center <= 0 )); then
    # The active step already exceeds the median (often paused/idle time, per
    # caveat (a), or a genuinely slow step) — a positive band would be misleading.
    printf 'ETA: overdue — current step already exceeds the median (%s); may be paused/idle or slow [%s step(s) left]\n' \
      "$(_dur_human "$median")" "$remaining"
    return 0
  fi
  printf 'ETA (rough band): %s–%s  [%s step(s) left, median step %s]\n' \
    "$(_dur_human "$(( center / 2 ))")" "$(_dur_human "$(( center * 2 ))")" \
    "$remaining" "$(_dur_human "$median")"
  printf '  note: wall-clock between past step completions (may include paused/idle time); xReview retries add variance.\n'
}

# Print the last ~40 lines of the worker's run log, rendered readable. Prefers the
# live run-<id>.log, else the archived logs/<id>.log. READ-ONLY: a one-shot
# `tail -n` — never -f/--pid, so it cannot attach to or disturb the worker.
_progress_log_tail() {
  local id="$1" live="$STATE_DIR/run-$id.log" arch="$STATE_DIR/logs/$id.log" log=""
  if [[ -f "$live" ]]; then log="$live"; elif [[ -f "$arch" ]]; then log="$arch"; fi
  if [[ -z "$log" ]]; then printf -- '--- run log: (none found) ---\n'; return 0; fi
  printf -- '--- run log (last 40 lines of %s) ---\n' "${log#"$STATE_DIR"/}"
  tail -n 40 "$log" | _render_stream
}

# Tier 3 (#110): a HEURISTIC, best-effort "within-step %" for SINGLE-step ledgers,
# inferred PASSIVELY from the worker's run log. Tier 1 already gives useful
# granularity for multi-step tasks; the gap is a 1-step ledger, which Tier 1 can
# only render coarsely (0 / half-credit / 100). This refines THAT one step by
# reading how far the worker has walked its own quality spine.
#
# READ-ONLY: one-shot jq over the log file — never -f/--pid/signal, so it cannot
# touch or disturb the live worker (same guarantee as _progress_log_tail).
#
# Detection reads ONLY tool_use ACTIONS (file-edit tool names + Bash command
# strings), NEVER assistant/user free text. This is deliberate: the item
# DESCRIPTION echoed into the worker's prompt literally lists milestone words
# ("APPROVED", "commit", "git staged", …), so a naive text grep would false-fire.
# Markers are further anchored to a shell COMMAND boundary (start of the Bash
# call, or after a ; && | separator) so a milestone token buried as a quoted
# argument (echo "git add", grep APPROVED, a `deputy set "<line-with-the-desc>"`)
# does not count. Highest matched rung wins → the estimate is monotonic.
# The printed number is a coarse ESTIMATE and is labelled as such.
_progress_within_step() {
  local id="$1" live="$STATE_DIR/run-$id.log" arch="$STATE_DIR/logs/$id.log" log=""
  # Deterministic precedence: the LIVE run log (an active worker) wins; otherwise
  # the archived per-id log. Same choice _progress_log_tail makes.
  if [[ -f "$live" ]]; then log="$live"; elif [[ -f "$arch" ]]; then log="$arch"; fi
  [[ -n "$log" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # WHOLE-file scan (not a tail): an early milestone must not scroll out of view
  # as the log grows. Tolerant parse — a torn/partial live line is skipped
  # (fromjson? // empty), never crashing the view. Newlines within a command are
  # flattened to spaces so a multi-line heredoc stays on one action line.
  local actions
  actions="$(jq -Rr '
    (fromjson? // empty) as $e
    | select(($e|type)=="object" and $e.type=="assistant")
    | $e.message.content[]?
    | select(.type=="tool_use")
    | if (.name|test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then "EDIT"
      elif .name=="Bash" then "BASH " + ((.input.command // "")|gsub("[\r\n]+";" "))
      else empty end
  ' "$log" 2>/dev/null)" || return 1
  [[ -n "$actions" ]] || return 1

  # Strip QUOTED spans ('…' and "…") from each action line before matching. The
  # boundary anchoring below is not shell-aware, so a separator or milestone token
  # buried inside a quoted argument — echo "x; deputy commit",
  # deputy set "<item-line-echoing-the-desc>" done — would otherwise create a
  # phantom command boundary. Removing quoted text first neutralizes that class;
  # the real invoked verbs (git add, deputy commit, codex exec, …) are never
  # themselves quoted, so this only drops arguments, never a genuine milestone.
  # Normalize away ALL shell quoting/escaping before matching, in order:
  #   1. single-quoted spans — literal in shell, no escapes ('…')
  #   2. double-quoted spans — escape-aware ("([^"\]|\.)*"), so echo "x\"; deputy
  #      commit" strips the whole arg instead of stopping at the escaped quote
  #   3. remaining backslash-escapes (\X) — an escaped char is LITERAL, so a bare
  #      echo x\; deputy commit must not let the \; form a phantom boundary
  # After this, only genuine unquoted/unescaped separators survive to anchor a
  # milestone; the real invoked verbs (git add, deputy commit, …) are never
  # quoted or escaped, so this only ever drops arguments, never a milestone.
  actions="$(printf '%s\n' "$actions" \
    | sed -E "s/'[^']*'//g" \
    | sed -E 's/"([^"\\]|\\.)*"//g' \
    | sed -E 's/\\.//g')"

  # Command-boundary prefix: start of a BASH action, or just after a ; && | | || .
  local bnd='(^BASH +|[;&|]+ *)'
  # Ascending ladder "weight|label|regex" — evaluated in order, LAST match wins.
  # Percentages are intentionally coarse ESTIMATES, not measurements. Regexes key
  # on MUTATING/confirming verbs (git add, deputy commit/protected, codex/gemini
  # review, review-log APPROVED, deputy done/merge) rather than read-only probes.
  local reached=5 label="step just started" row w rest l re
  for row in \
    "25|files edited|^EDIT\$" \
    "40|changes staged|${bnd}git( +-C +[^ ]+)?( +-[A-Za-z]+)* +add\\b" \
    "55|targeted tests run|${bnd}(bash +)?[^ ]*tests/test_[A-Za-z0-9_]+\\.sh\\b" \
    "65|full suite run|${bnd}(bash +)?[^ ]*tests/run\\.sh\\b" \
    "72|protected-path gate|${bnd}deputy +protected\\b" \
    "80|xReview invoked|${bnd}(codex +exec|gemini +-p|deputy +route +review|deputy +review-log)\\b" \
    "90|xReview APPROVED|${bnd}deputy +review-log\\b.*APPROVED" \
    "95|change committed|${bnd}deputy +commit\\b" \
    "99|merging / surfacing|${bnd}(deputy +done\\b|deputy +wt-remove\\b|deputy +set +.*(surfaced|done)|git +merge\\b)" \
  ; do
    w="${row%%|*}"; rest="${row#*|}"; l="${rest%%|*}"; re="${rest#*|}"
    if grep -Eq "$re" <<<"$actions"; then reached="$w"; label="$l"; fi
  done

  printf 'within-step (est.): ~%s%% — %s\n' "$reached" "$label"
  printf '  \xe2\x93\x98 HEURISTIC estimate inferred from run-log milestones; not exact.\n'
  return 0
}

# cmd_progress <id> — PURELY PASSIVE / READ-ONLY per-task progress view. Reads
# ONLY the waypoint ledger + the worker's run log; NEVER signals, follows
# (-f/--pid), or otherwise touches the running `claude -p` worker or its bwrap
# sandbox. Safe on a live, paused, stuck, or dead worker. (#108)
cmd_progress() {
  local id="${1:-}"
  [[ -n "$id" ]] || { printf 'deputy: progress requires an <id>\n' >&2; return 2; }
  id="${id#\#}"
  _valid_item_id "$id" || { printf 'deputy: progress: invalid id: %s\n' "$id" >&2; return 2; }
  _wp_require_jq || return 1

  local slug; slug="$(cmd_slug "$id" 2>/dev/null || true)"
  [[ -n "$slug" ]] || { printf 'deputy: progress: no task #%s found\n' "$id" >&2; return 1; }

  printf '── progress: #%s (%s) ──\n' "$id" "$slug"

  local wp; wp="$(_wp_json "$slug")"
  if [[ ! -f "$wp" ]]; then
    printf 'no waypoint ledger yet (task not started, or ran without the checkpoint spine).\n'
    _progress_log_tail "$id"
    return 0
  fi

  # Snapshot the ledger into memory (a single read) so a concurrent worker write
  # can't tear our reads and NOTHING is written to disk — the path stays literally
  # read-only. Ledger writes are atomic (mv), so one `cat` gets a consistent copy.
  local content; content="$(cat "$wp" 2>/dev/null)"
  if [[ -z "$content" ]] || ! jq -e . <<<"$content" >/dev/null 2>&1; then
    printf 'progress: waypoint is being updated — try again in a moment.\n'
    _progress_log_tail "$id"
    return 0
  fi

  local goal status updated current n succ inprog
  goal="$(jq -r '.goal // ""' <<<"$content")"
  status="$(jq -r '.status // "?"' <<<"$content")"
  updated="$(jq -r '.updated_at // ""' <<<"$content")"
  current="$(jq -r '.current_step // ""' <<<"$content")"
  n="$(jq -r '.steps | length' <<<"$content")"
  succ="$(jq -r '[.steps[]|select(.status=="succeeded")]|length' <<<"$content")"
  inprog="$(jq -r '[.steps[]|select(.status=="in_progress")]|length' <<<"$content")"

  printf 'status: %s\ngoal:   %s\n' "$status" "$goal"

  # ── Tier 1: step progress (in_progress step gets half credit) ────────────
  if [[ "$n" -gt 0 ]]; then
    local pct=$(( (2*succ + inprog) * 100 / (2*n) )); (( pct > 100 )) && pct=100
    local pfx='~'
    # Never imply completion the ledger hasn't confirmed; the denominator can
    # grow if the worker re-plans, so cap at '>=99%' until status=completed.
    if [[ "$status" != "completed" && "$pct" -ge 100 ]]; then pct=99; pfx='>='; fi
    printf 'progress: step %s of %s; %s of %s succeeded; %s%s%% by step count\n' \
      "${current:-–}" "$n" "$succ" "$n" "$pfx" "$pct"
    # ── Tier 3 (#110): within-step heuristic for a SINGLE-step ledger ─────────
    # Multi-step tasks get useful granularity from the step count above; the
    # coarse case is a 1-step ledger. When that single step is actively running
    # (inprog>=1 — keyed on the STEP, not a status string), refine it with a
    # passive run-log milestone estimate. Silent (returns non-zero) if there is
    # no log / no jq / no recognizable action yet.
    if [[ "$n" -eq 1 && "$inprog" -ge 1 ]]; then
      _progress_within_step "$id" || true
    fi
  else
    printf 'progress: (no steps planned yet)\n'
  fi

  # ── current step detail ──────────────────────────────────────────────────
  if [[ -n "$current" ]]; then
    local cpur cexp
    cpur="$(jq -r --arg s "$current" '.steps[]|select(.id==$s)|.purpose // ""' <<<"$content")"
    cexp="$(jq -r --arg s "$current" '.steps[]|select(.id==$s)|.expected_result // ""' <<<"$content")"
    printf 'current step %s: %s\n' "$current" "$cpur"
    [[ -n "$cexp" ]] && printf '  expected: %s\n' "$cexp"
  else
    printf 'current step: none active\n'
  fi

  # ── done-so-far digest ───────────────────────────────────────────────────
  local digest
  digest="$(jq -r '.steps[] | select(.status=="succeeded")
                   | "  ✓ [\(.id)] \(.actual_result.summary // .purpose // "")"
                     + (if (.actual_result.artifacts[0].step_commit // "") != ""
                        then " (\(.actual_result.artifacts[0].step_commit[0:8]))" else "" end)' <<<"$content")"
  if [[ -n "$digest" ]]; then printf 'done so far:\n%s\n' "$digest"
  else printf 'done so far: (nothing committed yet)\n'; fi

  # ── time since last update ───────────────────────────────────────────────
  local last_e; last_e="$(_iso_epoch "$updated" || true)"
  printf 'last update: %s' "$(_ago_human "$last_e")"
  [[ -n "$updated" ]] && printf '  (%s)' "$updated"
  printf '\n'

  # ── Tier 2: ETA band ─────────────────────────────────────────────────────
  _progress_eta "$content" "$slug" "$n" "$succ" "$current" "$status"

  # ── run-log tail (the worker's output so far) ────────────────────────────
  _progress_log_tail "$id"
  return 0
}

cmd_watch() {
  local _wonce=0 _wapply=0 _wa _wid=""
  for _wa in "$@"; do case "$_wa" in
    --once)  _wonce=1 ;;
    --apply) _wapply=1 ;;
    '#'[0-9]*|[0-9]*)
      # #108: a bare id (scanned from ANY position — 'watch <id> --once' or
      # 'watch --once <id>') selects the passive per-task progress view.
      local _cand="${_wa#\#}"
      if _valid_item_id "$_cand"; then _wid="$_cand"
      else printf 'deputy: watch: unknown argument: %s\n' "$_wa" >&2; return 2; fi ;;
    *) printf 'deputy: watch: unknown argument: %s\n' "$_wa" >&2; return 2 ;;
  esac; done

  # #108: numeric id → one-shot read-only progress snapshot, dispatched BEFORE any
  # monitor/tail/PID logic so the read-only guarantee holds regardless of flags.
  if [[ -n "$_wid" ]]; then cmd_progress "$_wid"; return $?; fi

  # Queue overview once at start (the former 'deputy reflect'). --apply also writes the
  # learnings snapshot and is a one-shot (no monitor loop).
  if [[ "$_wapply" -eq 1 ]]; then _queue_overview --apply; return $?; fi
  _queue_overview

  local d="$ACTIVE_RUN_DIR"
  local _wpoll=5 _wcanbeep=1 _wprevlive=0

  # Track the logs/ directory mtime as a run-completion signal: each worker run
  # archives a log file there, bumping the dir mtime — human queue edits do NOT
  # touch it, so this is tighter than BACKLOG mtime and handles same-item reruns.
  local _wbeep_logdir_mtime=0 _wcur_logdir_mtime
  _wbeep_logdir_mtime="$(stat -c '%y' "$STATE_DIR/logs" 2>/dev/null || printf '0')"

  while true; do
    # ── live worker? ─────────────────────────────────────────────────────────
    if [[ -d "$d" ]] && _active_run_live "$d"; then
      _wprevlive=1
      local _wi_item _wi_pid _wi_id _wi_log _wi_i
      _wi_item="$(sed -n '1p' "$d/item" 2>/dev/null || true)"
      _wi_pid="$(sed -n '1p'  "$d/pid"  2>/dev/null || true)"
      _wi_id="$(_parse_item "$_wi_item")"; _wi_id="${_wi_id#*|}"; _wi_id="${_wi_id#*|}"; _wi_id="${_wi_id%%|*}"
      if ! _valid_item_id "$_wi_id"; then
        printf 'deputy: a worker is running but its item has no id to watch.\n' >&2
        [[ "$_wonce" -eq 1 ]] && return 1; sleep "$_wpoll"; continue
      fi
      _wi_log="$STATE_DIR/run-$_wi_id.log"
      for _wi_i in $(seq 1 20); do [[ -e "$_wi_log" ]] && break; sleep 0.25; done
      if [[ ! -e "$_wi_log" ]]; then
        printf 'deputy: worker #%s is starting; no output yet.\n' "$_wi_id" >&2
        [[ "$_wonce" -eq 1 ]] && return 0; sleep "$_wpoll"; continue
      fi
      printf 'deputy: watching #%s (pid %s) — Ctrl-C to detach (the run keeps going)...\n' "$_wi_id" "$_wi_pid" >&2
      # --pid: exit when the run process ends; -f follows the open fd cleanly across archive mv.
      # #66: render the stream-json log to readable text. Capture tail's exit (PIPESTATUS[0])
      # under set +e: only a CLEAN exit (run ended, tail rc 0) prints the archived line —
      # a Ctrl-C detach (tail killed, non-zero) must NOT falsely claim the run ended.
      local _w_had_e=0; [[ $- == *e* ]] && _w_had_e=1; set +e
      tail --pid="$_wi_pid" -f "$_wi_log" | _render_stream
      local _w_trc=${PIPESTATUS[0]}
      [[ "$_w_had_e" -eq 1 ]] && set -e
      [[ "$_w_trc" -eq 0 ]] && printf 'deputy: run #%s ended — output archived to %s/logs/%s.log\n' \
        "$_wi_id" "$STATE_DIR" "$_wi_id" >&2
      # non-zero trc = Ctrl-C detach — exit immediately (run still going; no quiescence check).
      # Zero trc (run ended cleanly): fall through to quiescence check, even with --once.
      [[ "$_w_trc" -ne 0 ]] && return 0
      continue  # run ended cleanly → re-check immediately for quiescence (+ --once digest)
    fi

    # ── worker just ended (observed live) → re-arm ───────────────────────────
    if [[ "$_wprevlive" -eq 1 ]]; then _wcanbeep=1; fi
    _wprevlive=0

    # ── poll the queue ────────────────────────────────────────────────────────
    local _wr; _wr="$(_runnable_count)"
    local _ws; _ws="$(_attention_count)"   # surfaced + failed + deferred (all attention states)

    # Re-arm if a new run was archived since the last beep (logs/ dir mtime changes
    # on every run-complete; unaffected by human queue edits or status reads).
    _wcur_logdir_mtime="$(stat -c '%y' "$STATE_DIR/logs" 2>/dev/null || printf '0')"
    if [[ "$_wcanbeep" -eq 0 && "$_wcur_logdir_mtime" != "$_wbeep_logdir_mtime" ]]; then _wcanbeep=1; fi

    # Totally empty — friendly exit
    if [[ "$_wr" -eq 0 && "$_ws" -eq 0 ]]; then
      printf 'deputy: nothing to watch (queue empty — no running worker, no attention or runnable items).\n'
      return 0
    fi

    # Runnable items queued — stay quiet (not quiescent yet)
    if [[ "$_wr" -gt 0 ]]; then
      [[ "$_wonce" -eq 1 ]] && return 0
      sleep "$_wpoll"; continue
    fi

    # Quiescent: runnable==0, an attention item exists — beep + attention digest (once per batch)
    if [[ "$_wcanbeep" -eq 1 ]]; then
      _watch_beep
      _attention_digest
      _wcanbeep=0
      _wbeep_logdir_mtime="$_wcur_logdir_mtime"  # snapshot logs/ mtime at beep for re-arm
    fi

    [[ "$_wonce" -eq 1 ]] && return 0
    sleep "$_wpoll"
  done
}

# ── #109: 'deputy test [--changed] [name...]' — run the suite, a named subset, or only the
# tests AFFECTED by the working-tree diff. FAIL-SAFE: any change it can't confidently map to a
# test runs the FULL suite (never a silent skip). Automates the #89 targeted phase.

# Full-suite command: the project's test_cmd, else this repo's tests/run.sh.
_full_test_cmd() {
  local tc; tc="$(_config_get test_cmd)"
  [[ -n "$tc" ]] && { printf '%s' "$tc"; return 0; }
  [[ -f "$ROOT/tests/run.sh" ]] && { printf 'bash tests/run.sh'; return 0; }
  return 1
}

# Names of bin/deputy.sh functions whose lines changed (unstaged+staged). Emits __TOPLEVEL__
# if any changed line is outside every function (git's own function context is unreliable for
# shell, so we map changed line numbers to the enclosing 'name() {' ourselves).
_diff_changed_functions() {
  local hu=0 hs=0
  git -C "$ROOT" diff --quiet -- bin/deputy.sh 2>/dev/null || hu=1
  git -C "$ROOT" diff --cached --quiet -- bin/deputy.sh 2>/dev/null || hs=1
  [[ "$hu" -eq 0 && "$hs" -eq 0 ]] && return 0
  # Both staged AND unstaged edits: staged hunk line numbers would be mapped against a
  # working-tree file whose lines the unstaged edits shifted → can't map safely → FULL.
  [[ "$hu" -eq 1 && "$hs" -eq 1 ]] && { printf '__TOPLEVEL__\n'; return 0; }
  local raw
  raw="$( { git -C "$ROOT" diff --unified=0 -- bin/deputy.sh; git -C "$ROOT" diff --cached --unified=0 -- bin/deputy.sh; } 2>/dev/null )"
  # A deletion-only hunk (new count 0) has no new-side lines to map to a function, so a removed
  # function would be missed → fail safe to FULL.
  printf '%s\n' "$raw" | grep -qE '^@@ [^@]*\+[0-9]+,0 @@' && { printf '__TOPLEVEL__\n'; return 0; }
  local changed
  changed="$(printf '%s\n' "$raw" \
    | awk '/^@@ / { if (match($0,/\+[0-9]+(,[0-9]+)?/)) { s=substr($0,RSTART+1,RLENGTH-1);
        if (index(s,",")) { split(s,p,","); st=p[1]+0; ct=p[2]+0 } else { st=s+0; ct=1 }
        for(i=0;i<ct;i++) print st+i } }' | sort -un )"
  [[ -n "$changed" ]] || return 0
  awk -v CH="$changed" '
    BEGIN { n=split(CH,a,"\n"); for(i=1;i<=n;i++) want[a[i]+0]=1; fn="" }
    {
      # enter a function on its "name() {" definition; a changed def line maps to that function
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/) { fn=$1; sub(/\(.*/,"",fn) }
      if (NR in want) { if (fn=="") top=1; else seen[fn]=1 }
      if ($0 ~ /^\}/) fn=""   # a column-0 "}" ends the function; later lines are top-level
    }
    END { for (k in seen) print k; if (top) print "__TOPLEVEL__" }
  ' "$ROOT/bin/deputy.sh"
}

# Map a changed function → test basenames via tests/test-map, then the cmd_<X>→test_<X>
# convention. Non-zero (empty) when unmapped → caller falls back to the full suite.
_tests_for_function() {
  local fn="$1" line
  if [[ -f "$ROOT/tests/test-map" ]]; then
    line="$(grep -E "^[[:space:]]*${fn}[[:space:]]*:" "$ROOT/tests/test-map" 2>/dev/null | head -1)"
    [[ -n "$line" ]] && { printf '%s' "${line#*:}"; return 0; }
  fi
  if [[ "$fn" == cmd_* && -f "$ROOT/tests/test_${fn#cmd_}.sh" ]]; then
    printf 'test_%s' "${fn#cmd_}"; return 0
  fi
  return 1
}

# Echo the affected test basenames for the working-tree diff, or the token FULL (fail-safe).
_affected_tests() {
  local files f sel="" fn fns t b
  # working-tree + staged + UNTRACKED (a new source/hook/test file must not be silently missed;
  # --exclude-standard respects .gitignore so .deputy/ scratch etc. is excluded).
  files="$( { git -C "$ROOT" diff --name-only; git -C "$ROOT" diff --cached --name-only; \
              git -C "$ROOT" ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
  [[ -n "$files" ]] || return 0   # nothing changed
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      tests/test-map|tests/lib.sh|tests/run.sh) printf 'FULL'; return 0 ;;   # harness change → all
      tests/test_*.sh)        b="${f#tests/}"; sel+=" ${b%.sh}" ;;           # a changed test → run itself
      bin/deputy.sh)
        fns="$(_diff_changed_functions)"
        [[ "$fns" == *"__TOPLEVEL__"* ]] && { printf 'FULL'; return 0; }
        while IFS= read -r fn; do
          [[ -n "$fn" ]] || continue
          t="$(_tests_for_function "$fn")" || { printf 'FULL'; return 0; }
          sel+=" $t"
        done <<< "$fns"
        ;;
      hooks/guardrail.sh)     sel+=" test_guardrail" ;;
      hooks/session-start.sh) sel+=" test_hook" ;;
      .deputy/*)              : ;;   # deputy runtime state (normally gitignored) — not source
      VERSION)                sel+=" test_version test_release test_release_notes" ;;   # drives version/release
      skills/*)               : ;;   # SKILL prose — no test
      README.md|CHANGELOG.md|*.md|docs/*) : ;;   # docs — no test
      *)                      printf 'FULL'; return 0 ;;   # unknown → fail safe
    esac
  done <<< "$files"
  printf '%s' "$sel" | tr ' ' '\n' | sed '/^$/d;s/\.sh$//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

_run_test_files() {
  local rc=0 n
  for n in "$@"; do
    n="${n%.sh}"; n="${n#tests/}"
    [[ -f "$ROOT/tests/$n.sh" ]] || { printf 'deputy: test: no such test: %s\n' "$n" >&2; rc=1; continue; }
    printf '== tests/%s.sh ==\n' "$n"
    ( cd "$ROOT" && bash "tests/$n.sh" ) || rc=1
  done
  return "$rc"
}

cmd_test() {
  local changed=0; local -a names=()
  while [[ $# -gt 0 ]]; do case "$1" in
    --changed) changed=1; shift ;;
    -*) printf 'deputy: test: unknown flag: %s\n' "$1" >&2; return 2 ;;
    *)  names+=( "$1" ); shift ;;
  esac; done
  if [[ "${#names[@]}" -gt 0 ]]; then _run_test_files "${names[@]}"; return $?; fi
  if [[ "$changed" -eq 1 ]]; then
    local aff; aff="$(_affected_tests)"
    if [[ -z "$aff" ]]; then printf 'deputy: test --changed: no changes detected — nothing to run.\n'; return 0; fi
    if [[ "$aff" == "FULL" ]]; then
      printf 'deputy: test --changed: change not fully mapped — running the FULL suite.\n'
    else
      printf 'deputy: test --changed: affected tests: %s\n' "$aff"
      _run_test_files $aff; return $?
    fi
  fi
  local full; full="$(_full_test_cmd)" || { printf 'deputy: test: no test command (set config test_cmd, or add tests/run.sh)\n' >&2; return 2; }
  ( cd "$ROOT" && eval "$full" )
}

main() {
  local cmd="${1:-help}"
  # #72: `deputy <cmd> --help|-h` prints focused help for that command, then exits.
  # (Bare `-h`/`--help`/`help` with no subcommand is the top-level usage, handled in
  # the dispatch below. Intercept here so it works before each command's own parsing.)
  case "$cmd" in
    -h|--help|help) ;;
    *)
      local _ha _hfull="" _hhelp=0
      for _ha in "${@:2}"; do
        [[ "$_ha" == "--" ]] && break   # respect the `--` escape (e.g. `add -- "--desc"`)
        [[ "$_ha" == "--full" ]] && _hfull="--full"
        [[ "$_ha" == "-h" || "$_ha" == "--help" ]] && _hhelp=1
      done
      (( _hhelp )) && { _cmd_help "$cmd" "$_hfull"; return 0; } ;;
  esac
  _migrate_trails   # #70: one-shot sweep of any flat runtime trails into subfolders (no-op once done)
  # #67: keep the agent's claim heartbeat fresh whenever the orchestrator drives a
  # spine verb (no-op unless an agent-owned claim/run for this $PPID exists), so its
  # claim stays live while actively working and auto-EXPIRES once it stops.
  case "$cmd" in
    wt-create|wt-remove|start|done|plan|steps|set-step|resume|commit) _active_run_refresh ;;
  esac
  case "$cmd" in
    help|-h|--help)
      local _hfull="" _ha2
      for _ha2 in "${@:2}"; do [[ "$_ha2" == "--full" ]] && _hfull="--full" && break; done
      usage "$_hfull"; return 0 ;;
    version|--version|-V) cmd_version; return $? ;;
    _parse) _parse_item "${2:-}"; printf '\n'; return 0 ;;
    list) shift; cmd_list "$@"; return $? ;;
    _serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" && printf '\n' || return 1 ;;
    add) shift; cmd_add "$@" ;;
    accept) shift; cmd_accept "$@"; return $? ;;     # #113: the frozen acceptance record
    verify) shift; cmd_verify "$@"; return $? ;;     # #113: red / green / bite / smoke gates
    slug) shift; cmd_slug "${1:-}"; return $? ;;
    status) cmd_status; return 0 ;;
    test) shift; cmd_test "$@"; return $? ;;
    watch|tail) shift; cmd_watch "$@"; return $? ;;
    progress) shift; cmd_progress "${1:-}"; return $? ;;   # #108: passive read-only per-task progress
    pick) cmd_pick; return 0 ;;
    pickup) shift; cmd_pickup "${1:-}"; return $? ;;
    set) shift; cmd_set "$@"; return $? ;;
    claim) shift; cmd_claim "$@"; return $? ;;
    recover) cmd_recover; return $? ;;   # propagate recovery failure (#47 rc-propagation)
    doctor) cmd_doctor; return 0 ;;
    review) shift; cmd_review "$@"; return $? ;;
    clean) shift; cmd_clean "$@"; return $? ;;
    reflect) shift   # #removed: 'reflect' folded into 'watch'; kept as a back-compat alias
      printf 'deputy: "reflect" is now part of "deputy watch" — use "deputy watch".\n' >&2
      cmd_watch --once "$@"; return $? ;;
    release) shift; cmd_release "$@"; return $? ;;
    release-notes) cmd_release_notes; return $? ;;
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
    route) shift; _route "${1:-}" "${2:-}" "${3:-}"; return $? ;;
    avail) _availability; return 0 ;;
    probe) shift; _probe "${1:-}"; return 0 ;;
    cron) shift; cmd_cron "$@"; return $? ;;
    _resethour) shift; _parse_reset_hour "${1:-}"; return 0 ;;
    _resetsecs) shift; _parse_reset_secs "${1:-}"; return 0 ;;
    config) shift; cmd_config "$@"; return $? ;;
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
