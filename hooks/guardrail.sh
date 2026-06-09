#!/usr/bin/env bash
# hooks/guardrail.sh — Deputy risky-op guardrail (Claude Code PreToolUse hook).
# Best-effort tripwire: when DEPUTY_GUARDED=1, DENY known-risky tool calls by the spawned
# orchestrator so it surfaces them instead. Reads PreToolUse JSON on stdin; denies via
# exit 2 + a stderr reason (Claude feeds stderr back to the model). NOT a sandbox — see
# docs/superpowers/specs/2026-06-08-deputy-risky-op-guardrail-design.md.
set -uo pipefail

# Self-gate: only enforce for the guarded orchestrator session.
[[ "${DEPUTY_GUARDED:-}" == "1" ]] || exit 0

input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "guardrail: jq missing; denying for safety" >&2; exit 2; }
# Validate that input is parseable JSON; fail-closed if not.
printf '%s' "$input" | jq empty >/dev/null 2>&1 || { echo "guardrail: invalid JSON input; denying for safety" >&2; exit 2; }

deny() {
  echo "BLOCKED by deputy guardrail: $1 Do NOT retry or work around it — run: deputy set \"<item-line>\" surfaced (with a note explaining why), then stop." >&2
  exit 2
}

# Normalize whitespace (tabs/newlines -> space) for pattern matching. We deliberately do
# NOT strip shell quotes/backslashes: doing so causes false positives on legitimate
# commands that mention risky tokens as DATA (e.g. `grep "rm -rf" .`, a commit message
# saying "remove rm -rf"). Quote/escape-based evasion (--re'move') is the accepted
# adversarial out-of-scope class per the spec threat model (best-effort tripwire).
_norm() { printf '%s' "$1" | tr '\t' ' ' | tr '\n' ' '; }

_bash_risky() {
  local n; n="$(_norm "$1")"
  # Strip a leading "git -C <path>" prefix so we check the actual subcommand.
  # This captures git subcommands even when invoked with a -C working-dir override.
  local bare_n; bare_n="$(printf '%s' "$n" | sed 's/git  *-C  *[^ ]*  */git /g')"
  local p
  for p in \
    '(^| )git +push' \
    'git +(-[^ ]+ +)*--(git-dir|work-tree)' \
    '(^| )GIT_(DIR|WORK_TREE)=' \
    '(^| )crontab( |$)' \
    'install\.sh' \
    '(^| )rm +(-[a-zA-Z]*[rRfF][a-zA-Z]*|--recursive|--force)' \
    '(^| )rm +([^ ]+ +)*-[a-zA-Z]*[rRfF]' \
    '(^| )rm +([^ ]+ +)*--(recursive|force)' \
    '(^| )git +branch +-[Dd]( |$)' \
    '(^| )git +branch +-f' \
    '(^| )git +update-ref' \
    '(^| )git +config +--(global|system)' \
    '(^| )git +worktree +remove +[^|;&]*--force' \
    '(^| )git +remote( |$)' \
    '(^| )sudo( |$)' \
    '(^| )gh +pr +merge' \
    '(^| )gh +[^|;&]*--delete-branch' \
    '(npm|pnpm|yarn) +[^|;&]*( -g|--global)' \
    '(^| )pip[0-9]* +install' \
    '(^| )apt(-get)?( |$)' \
    '(^| )brew +install' \
    ; do
    printf '%s' "$bare_n" | grep -Eq "$p" && return 0
  done
  # deputy cron lifecycle is user-owned; check EACH segment — a segment touching
  # `deputy cron` is allowed only if it is --reschedule (the SKILL's quota failover) AND
  # carries no --ensure/--remove. Per-segment catches chained bypasses
  # (e.g. `deputy cron --reschedule x; deputy cron --remove`).
  local _seg
  while IFS= read -r _seg; do
    printf '%s' "$_seg" | grep -Eq '(^| )deputy +cron' || continue
    if printf '%s' "$_seg" | grep -Eq '(^| )deputy +cron +--reschedule' \
       && ! printf '%s' "$_seg" | grep -Eq -- '--(ensure|remove)'; then
      continue
    fi
    return 0
  done < <(printf '%s\n' "$bare_n" | tr ';|&' '\n')
  # reset --hard / clean -f: check each command segment independently.
  # Split on shell separators (;, &&, ||, |) and check each segment that contains
  # reset --hard or clean -f is also scoped to DEPUTY_WT via -C with canonical path.
  local wt_real; wt_real="$(realpath -m -- "${DEPUTY_WT:-}" 2>/dev/null)" || wt_real=""
  local seg
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed 's/^ *//;s/ *$//')"
    [[ -z "$seg" ]] && continue
    # Normalize tabs in segment too.
    local normseg; normseg="$(_norm "$seg")"
    if printf '%s' "$normseg" | grep -Eq 'git +[^|;&]*(reset +--hard|clean +-[a-zA-Z]*[fF][a-zA-Z]*)'; then
      # Extract the -C path (if present) and canonicalize to compare with wt.
      local cpath; cpath="$(printf '%s' "$normseg" | grep -oE 'git +-C +[^ ]+' | sed "s/git  *-C  *//;s/^[\"']//;s/[\"']$//")"
      if [[ -n "$cpath" && -n "$wt_real" ]]; then
        local creal; creal="$(realpath -m -- "$cpath" 2>/dev/null)" || creal=""
        # Only allow if cpath resolves to exactly the wt (or a path inside it).
        case "$creal/" in
          "$wt_real/"*) ;;  # scoped to wt: this segment is ok
          *) return 0 ;;     # not scoped: deny
        esac
      else
        # No -C path or wt unknown: deny (fail-closed).
        return 0
      fi
    fi
  done < <(printf '%s\n' "$n" | tr ';|&' '\n')
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
  # the two permitted state files — slug must be a single component (no slash)
  local slug="${rp#"$root"/.deputy/}"
  case "$slug" in
    *.questions.md|*.fail.md)
      [[ "$slug" != */* ]] && return 1 ;;
  esac
  return 0                                   # everything else -> deny
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
case "$tool" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    [[ -n "$cmd" ]] || deny "Bash call with no command (fail-closed)."
    _bash_risky "$cmd" && deny "risky command [$(printf '%s' "$cmd" | head -c 80)]."
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
