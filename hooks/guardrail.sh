#!/usr/bin/env bash
# hooks/guardrail.sh — Deputy risky-op guardrail (Claude Code PreToolUse hook).
# Best-effort tripwire: when DEPUTY_GUARDED=1, DENY known-risky tool calls by the spawned
# orchestrator so it surfaces them instead. Reads PreToolUse JSON on stdin; denies via
# exit 2 + a stderr reason (Claude feeds stderr back to the model). NOT a sandbox — see
# docs/superpowers/specs/2026-06-08-deputy-risky-op-guardrail-design.md.
set -uo pipefail

# Fast no-op for ordinary sessions. The heavier JSON/jq path is needed only for
# guarded Deputy workers or when an active-run marker exists for this repo.
if [[ "${DEPUTY_GUARDED:-}" != "1" ]]; then
  _root="${DEPUTY_ROOT:-}"
  [[ -n "$_root" && -d "$_root/.deputy/active-run.lock" ]] || exit 0
fi

input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "guardrail: jq missing; denying for safety" >&2; exit 2; }
# Validate that input is parseable JSON; fail-closed if not.
printf '%s' "$input" | jq empty >/dev/null 2>&1 || { echo "guardrail: invalid JSON input; denying for safety" >&2; exit 2; }

deny() {
  echo "BLOCKED by deputy guardrail: $1 Do NOT retry or work around it — run: deputy set \"<item-line>\" surfaced (with a note explaining why), then stop." >&2
  exit 2
}

_pid_start_time() {
  local pid="$1"
  ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true
}

_active_run_blocks() {
  local root="${DEPUTY_ROOT:-}" d pid recorded_start actual_start
  [[ -n "$root" ]] || return 1
  d="$root/.deputy/active-run.lock"
  [[ -d "$d" ]] || return 1
  pid="$(sed -n '1p' "$d/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "${DEPUTY_ACTIVE_RUN_PID:-}" == "$pid" ]] && return 1
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_start="$(sed -n '1p' "$d/start_time" 2>/dev/null || true)"
  if [[ -n "$recorded_start" ]]; then
    actual_start="$(_pid_start_time "$pid")"
    [[ "$actual_start" == "$recorded_start" ]] || return 1
  fi
  return 0
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

# A live active-run marker means an autonomous Deputy process owns writes for this
# repo. If this hook is active in an interactive session, fail closed for mutating
# tools unless the session was launched by that owner.
if _active_run_blocks; then
  case "$tool" in
    Bash|Edit|Write|MultiEdit|NotebookEdit)
      deny "active Deputy run in progress; mutating tool [$tool] is blocked until .deputy/active-run.lock is released."
      ;;
  esac
fi

# Self-gate for the normal risky-op policy: only enforce it for the guarded
# orchestrator session. The active-run check above can still protect an
# interactive session if this hook is installed there.
[[ "${DEPUTY_GUARDED:-}" == "1" ]] || exit 0

# Normalize for pattern matching: tabs -> space, and NEWLINES -> ';' (a command
# separator) so a risky command on a later line of a multi-line script is still split
# into its own anchored segment (not hidden mid-line after a collapse-to-space). We
# deliberately do NOT strip shell quotes/backslashes: that causes false positives on
# legitimate commands that mention risky tokens as DATA (e.g. `grep "rm -rf" .`, a commit
# message saying "remove rm -rf"). Quote/escape-based evasion (--re'move') is the accepted
# adversarial out-of-scope class per the spec threat model (best-effort tripwire).
_norm() { printf '%s' "$1" | tr '\t' ' ' | tr '\n' ';'; }

_bash_risky() {
  local raw_cmd="$1" session_cwd="${2:-}"
  local n; n="$(_norm "$raw_cmd")"

  # Fix 1: command-position anchoring via segment splitting.
  # Split the normalized command on shell separators (;, |, &, (, ) ) to get
  # individual command segments. Denylist patterns are matched against the FIRST
  # word of each segment (using ^[[:space:]]* anchor), so risky tokens that appear
  # only as DATA inside a quoted argument (commit message, echo string, grep
  # pattern) do NOT match — they appear mid-segment, not as the leading command.
  # We also strip a leading "git -C <path>" prefix from each segment so git
  # subcommands with a -C working-dir override are checked correctly.
  # Note: splitting on '(' catches subshell invocations like `(rm -rf foo)`.

  _check_segment() {
    local s="$1"
    local bare_s; bare_s="$(printf '%s' "$s" | sed 's/git  *-C  *[^ ]*  */git /g')"
    local p
    for p in \
      '^[[:space:]]*git +push' \
      '^[[:space:]]*git +(-[^ ]+ +)*--(git-dir|work-tree)' \
      '^[[:space:]]*GIT_(DIR|WORK_TREE)=' \
      '^[[:space:]]*crontab( |$)' \
      '[^ /]*inst_deputy\.sh( |$)' \
      '^[[:space:]]*rm +(-[a-zA-Z]*[rRfF][a-zA-Z]*|--recursive|--force)' \
      '^[[:space:]]*rm +([^ ]+ +)*-[a-zA-Z]*[rRfF]' \
      '^[[:space:]]*rm +([^ ]+ +)*--(recursive|force)' \
      '^[[:space:]]*git +branch +-[Dd]( |$)' \
      '^[[:space:]]*git +branch +-f' \
      '^[[:space:]]*git +update-ref' \
      '^[[:space:]]*git +config +--(global|system)' \
      '^[[:space:]]*git +worktree +remove +[^|;&]*--force' \
      '^[[:space:]]*git +remote( |$)' \
      '^[[:space:]]*sudo( |$)' \
      '^[[:space:]]*gh +pr +merge' \
      '^[[:space:]]*gh +[^;&|]*--delete-branch' \
      '^[[:space:]]*(npm|pnpm|yarn) +[^;&|]*( -g|--global)' \
      '^[[:space:]]*pip[0-9]* +install' \
      '^[[:space:]]*apt(-get)?( |$)' \
      '^[[:space:]]*brew +install' \
      ; do
      printf '%s' "$bare_s" | grep -Eq "$p" && return 0
    done
    return 1
  }

  # Split on ;|&() and check each segment. A match in any segment → deny.
  local seg
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed 's/^ *//;s/ *$//')"
    [[ -z "$seg" ]] && continue
    _check_segment "$(_norm "$seg")" && return 0
  done < <(printf '%s\n' "$n" | tr ';|&()' '\n')

  # deputy cron lifecycle is user-owned; check EACH segment — a segment touching
  # `deputy cron` is allowed only if it is --reschedule (the SKILL's quota failover) AND
  # carries no --ensure/--remove. Per-segment catches chained bypasses
  # (e.g. `deputy cron --reschedule x; deputy cron --remove`).
  local _seg
  while IFS= read -r _seg; do
    local _snorm; _snorm="$(_norm "$_seg")"
    printf '%s' "$_snorm" | grep -Eq '^[[:space:]]*deputy +cron' || continue
    if printf '%s' "$_snorm" | grep -Eq '^[[:space:]]*deputy +cron +--reschedule' \
       && ! printf '%s' "$_snorm" | grep -Eq -- '--(ensure|remove)'; then
      continue
    fi
    return 0
  done < <(printf '%s\n' "$n" | tr ';|&()' '\n')

  # Fix 2: reset --hard / clean -f — honor session cwd.
  # A reset/clean segment is ALLOWED when it is plausibly scoped to DEPUTY_WT via:
  #   (a) git -C <path> where path resolves inside DEPUTY_WT (existing logic), OR
  #   (b) the session cwd (JSON .cwd) resolves inside DEPUTY_WT, OR
  #   (c) a same-call `cd <path>` into DEPUTY_WT before the reset in the chain,
  #       tracking the LAST cd so 'cd $WT; cd /tmp; git reset' is still denied.
  # Otherwise DENY (fail-closed).
  local wt_real; wt_real="$(realpath -m -- "${DEPUTY_WT:-}" 2>/dev/null)" || wt_real=""
  # (b) resolve session cwd once.
  local cwd_real; cwd_real=""
  if [[ -n "$session_cwd" && -n "$wt_real" ]]; then
    cwd_real="$(realpath -m -- "$session_cwd" 2>/dev/null)" || cwd_real=""
  fi
  # Helper: true if $1 resolves inside wt_real.
  _inside_wt() {
    local _p; _p="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ -n "$_p" && -n "$wt_real" ]] || return 1
    case "$_p/" in "$wt_real/"*) return 0 ;; esac
    return 1
  }
  # Track the effective cwd as we walk segments (updated by cd commands).
  # Starts as $cwd_real (session cwd from JSON), or "" if unknown.
  local effective_cwd="$cwd_real"
  local rseg
  while IFS= read -r rseg; do
    rseg="$(printf '%s' "$rseg" | sed 's/^ *//;s/ *$//')"
    [[ -z "$rseg" ]] && continue
    local normseg; normseg="$(_norm "$rseg")"
    # Track cd commands in this segment to update effective_cwd.
    local cdpath; cdpath="$(printf '%s' "$normseg" | grep -oE '(^|[[:space:]])cd +[^ ]+' | sed 's/^ *cd  *//' | head -1)"
    if [[ -n "$cdpath" ]]; then
      local cdreal; cdreal="$(realpath -m -- "$cdpath" 2>/dev/null)" || cdreal=""
      effective_cwd="$cdreal"
    fi
    if printf '%s' "$normseg" | grep -Eq '^[[:space:]]*git +[^|;&]*(reset +--hard|clean +-[a-zA-Z]*[fF][a-zA-Z]*)'; then
      # (a) -C path check.
      local cpath; cpath="$(printf '%s' "$normseg" | grep -oE 'git +-C +[^ ]+' | sed "s/git  *-C  *//;s/^[\"']//;s/[\"']$//")"
      if [[ -n "$cpath" && -n "$wt_real" ]]; then
        local creal; creal="$(realpath -m -- "$cpath" 2>/dev/null)" || creal=""
        case "$creal/" in
          "$wt_real/"*) continue ;;  # scoped to wt: this segment is ok
          *) return 0 ;;             # not scoped: deny
        esac
      fi
      # (b)/(c) effective cwd (from session JSON or prior cd) is inside wt: allow.
      if [[ -n "$effective_cwd" ]] && _inside_wt "$effective_cwd"; then
        continue
      fi
      # No -C, no safe cwd, no cd: deny (fail-closed).
      return 0
    fi
  done < <(printf '%s\n' "$n" | tr ';|&()' '\n')
  return 1
}

_path_outside_wt() {
  local p="$1"
  [[ -n "$p" ]] || return 0                 # fail-closed: empty path -> deny
  # Fail-closed if DEPUTY_WT or DEPUTY_ROOT unset/empty.
  [[ -n "${DEPUTY_WT:-}" ]] || return 0
  [[ -n "${DEPUTY_ROOT:-}" ]] || return 0
  [[ "$p" = /* ]] || p="$PWD/$p"            # relative -> resolve against cwd (the worktree)
  local rp wt root
  rp="$(realpath -m -- "$p" 2>/dev/null)"   || return 0
  wt="$(realpath -m -- "$DEPUTY_WT" 2>/dev/null)" || return 0  # fail-closed if wt unresolvable
  root="$(realpath -m -- "$DEPUTY_ROOT" 2>/dev/null)" || return 0
  # Fail-closed if either resolved to empty (e.g. realpath returned empty string).
  [[ -n "$wt" ]] || return 0
  [[ -n "$root" ]] || return 0
  case "$rp/" in "$wt/"*) return 1 ;; esac  # inside the worktree -> allow
  # the two permitted Write/Edit state files — slug must be a single component (no slash).
  # NOTE: .deputy/<slug>.review.md is intentionally NOT here — the xReview trail is
  # append-only and may be written only via `deputy review-log` (a Bash command, which
  # this hook does not path-check). Direct Write/Edit to it stays denied so it can't be
  # overwritten.
  local slug="${rp#"$root"/.deputy/}"
  case "$slug" in
    *.questions.md|*.fail.md)
      [[ "$slug" != */* ]] && return 1 ;;
  esac
  return 0                                   # everything else -> deny
}

# #60: a guarded (spawned) worker must SURFACE its branch for human merge-review — it must
# NOT auto-merge to the default branch. Block any `git merge` segment unless the repo opts
# in with `auto_merge=1`. A human (unguarded orchestrator) merging is unaffected (the hook
# only runs when DEPUTY_GUARDED=1). Catches the standard `git merge ...`, chained `cd && git
# merge`, env-prefixed, quoted `git -C`, and common leading wrappers (time/if/env/sudo/…,
# incl. simple flags). Best-effort (like the rest of this tripwire): an exotic wrapper with
# a separate flag-argument can still pass — the primary mechanism is the SKILL surfacing the
# branch; this hook is the backstop for the forms a cooperative worker actually emits.
# Returns 0 = blocked.
_git_merge_blocked() {
  local cmd="$1" am seg s
  am="$(grep -E '^auto_merge=' "${DEPUTY_ROOT:-}/.deputy/config" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
  [[ "$am" == "1" ]] && return 1             # explicitly allowed
  while IFS= read -r seg; do
    s="$(_norm "$seg")"; s="${s#"${s%%[![:space:]]*}"}"   # normalize tabs, ltrim
    # Strip leading shell wrappers and VAR=val assignments so wrapped forms can't slip a
    # merge past the first-token check (e.g. `if git merge`, `time git merge`, `X=1 git merge`).
    while :; do
      case "$s" in
        if\ *|then\ *|else\ *|elif\ *|do\ *|while\ *|until\ *|time\ *|env\ *|command\ *|builtin\ *|exec\ *|sudo\ *|nice\ *|nohup\ *|stdbuf\ *|ionice\ *) s="${s#* }" ;;
        '!'\ *)          s="${s#* }" ;;        # negation
        -*\ *)           s="${s#* }" ;;        # a wrapper flag (e.g. time -p, env -i, nice -n)
        [A-Za-z_]*=*\ *) s="${s#* }" ;;        # leading env assignment
        *) break ;;
      esac
      s="${s#"${s%%[![:space:]]*}"}"          # ltrim
    done
    # Strip a `git -C <path>` prefix (path may be double-quoted with spaces).
    s="$(printf '%s' "$s" | sed -E 's/^git[[:space:]]+-C[[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+/git /')"
    printf '%s' "$s" | grep -Eq '^[[:space:]]*git[[:space:]]+merge([[:space:]]|$)' && return 0
  done < <(printf '%s\n' "$cmd" | tr ';|&()' '\n')
  return 1
}

# Fix 2: extract top-level .cwd from the PreToolUse JSON (session working directory).
session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
case "$tool" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    [[ -n "$cmd" ]] || deny "Bash call with no command (fail-closed)."
    _bash_risky "$cmd" "$session_cwd" && deny "risky command [$(printf '%s' "$cmd" | head -c 80)]."
    _git_merge_blocked "$cmd" && deny "auto-merge by a spawned worker is disabled (auto_merge!=1). Do NOT 'git merge' — SURFACE the item for human review instead: 'deputy set \"<line>\" surfaced' and leave the deputy/<slug> branch for a human to merge."
    ;;
  Edit|Write|MultiEdit)
    path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
    _path_outside_wt "$path" && deny "write outside the worktree [${path:-<none>}]."
    ;;
  NotebookEdit)
    path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty')"
    _path_outside_wt "$path" && deny "notebook write outside the worktree [${path:-<none>}]."
    ;;
esac
exit 0
