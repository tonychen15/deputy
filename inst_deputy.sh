#!/usr/bin/env bash
# inst_deputy.sh — install the Deputy runner (Plan 1 MVP).
#
#   inst_deputy.sh [link] [--prefix DIR] [--force]   symlink `deputy` (+ `inst_deputy.sh`) into DIR (default: $HOME/.local/bin)
#   inst_deputy.sh init [DIR]                        ensure the PATH link, then seed BACKLOG.md, .deputy/, CLAUDE.md guidance, and enable the cron heartbeat in DIR (default: cwd)
#   inst_deputy.sh help
#
# `link` puts the `deputy` command (and this installer) on your PATH; the runner
# resolves its target repo at call time ($DEPUTY_ROOT, else the git toplevel of
# your cwd). `init` first ensures that PATH link (so a first run can go straight
# to `init`), then prepares a specific repo's queue file and enables the cron
# heartbeat in one step.
#
# This script self-locates its own source tree (resolving a PATH symlink back to
# the real file), so once linked it runs from ANY directory — you never need to
# cd into the deputy checkout, and it works regardless of your current repo.
set -euo pipefail

# Portable `readlink -f` (BSD/macOS `readlink` has no `-f`): fully resolve a
# path's symlinks to an absolute location, following relative targets against
# each link's directory. Stops after 40 hops so a symlink cycle can't spin
# forever. Prints nothing (and succeeds) if the path doesn't exist, matching the
# `readlink -f ... 2>/dev/null` behaviour the idempotency checks below rely on.
_resolve() {
  local p="$1" d hops=0
  [[ -e "$p" || -L "$p" ]] || return 0
  while [[ -L "$p" ]]; do
    if (( ++hops > 40 )); then printf 'install: symlink loop resolving %s\n' "$1" >&2; return 1; fi
    d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
    p="$(readlink "$p")"
    [[ "$p" != /* ]] && p="$d/$p"
  done
  d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
  printf '%s/%s' "$d" "${p##*/}"
}

# Resolve a PATH symlink (e.g. ~/.local/bin/inst_deputy.sh) back to the real
# script so SRC_DIR points at the actual deputy checkout no matter where we are
# invoked from — works on BSD/macOS too (see _resolve).
_self="$(_resolve "${BASH_SOURCE[0]}")"
SRC_DIR="$(cd -P "$(dirname "$_self")" >/dev/null 2>&1 && pwd)"
unset _self
# Resolve to the canonical (main) worktree so running inst_deputy.sh from inside a transient
# git worktree (e.g. .deputy/wt-<slug>) never points the GLOBAL symlinks at an ephemeral
# path that vanishes on wt-remove. `git worktree list`'s FIRST entry is always the main
# worktree (robust even with --separate-git-dir); clear GIT_DIR/GIT_COMMON_DIR so an
# inherited env can't redirect resolution to an unrelated repo.
_wl="$(env -u GIT_DIR -u GIT_COMMON_DIR git -C "$SRC_DIR" worktree list --porcelain 2>/dev/null || true)"
if [[ "$_wl" == "worktree "* ]]; then          # first line is always the main worktree
  _main="${_wl%%$'\n'*}"; _main="${_main#worktree }"   # pure-bash first line, no pipe/SIGPIPE
  [[ -n "$_main" && -d "$_main" ]] && SRC_DIR="$_main"
fi
unset _wl _main
# Defense-in-depth: refuse to link from a transient deputy worktree path even if resolution failed.
case "$SRC_DIR" in *"/.deputy/wt"*) printf 'install: refusing to link from a transient worktree: %s\n' "$SRC_DIR" >&2; exit 1 ;; esac
RUNNER="$SRC_DIR/bin/deputy.sh"
INSTALLER="$SRC_DIR/inst_deputy.sh"
TEMPLATE="$SRC_DIR/templates/BACKLOG.md"

usage() {
  cat <<EOF
usage:
  inst_deputy.sh [link] [--prefix DIR] [--force]   symlink 'deputy' (+ this installer) into DIR (default: \$HOME/.local/bin)
  inst_deputy.sh init [DIR]                         ensure the PATH link, then seed BACKLOG.md, .deputy/, CLAUDE.md guidance, and enable cron heartbeat in DIR (default: cwd)
  inst_deputy.sh cron                               re-run 'deputy cron --ensure' (re-enable heartbeat; init already does this)
  inst_deputy.sh help
EOF
}

cmd_link() {
  local prefix="${DEPUTY_PREFIX:-$HOME/.local/bin}" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) prefix="${2:?install: --prefix needs a directory}"; shift 2 ;;
      --force)  force=1; shift ;;
      *) printf 'install: unexpected arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [[ -f "$RUNNER" ]] || { printf 'install: runner not found: %s\n' "$RUNNER" >&2; return 1; }
  [[ -x "$RUNNER" ]] || { printf 'install: runner is not executable: %s\n' "$RUNNER" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || printf 'install: NOTE: jq not found — the checkpoint spine needs jq (apt install jq / brew install jq).\n' >&2
  mkdir -p "$prefix" || return 1
  # Link the runner. We must NOT early-return when it's already linked: an
  # existing install predates the installer-self-link below, so re-running must
  # still fall through and drop inst_deputy.sh onto PATH (idempotent migration).
  local target="$prefix/deputy" runner_linked=0
  if [[ -L "$target" || -e "$target" ]]; then
    if [[ "$(_resolve "$target")" == "$(_resolve "$RUNNER")" ]]; then
      printf 'install: already linked: %s -> %s\n' "$target" "$RUNNER"
      runner_linked=1
    elif [[ "$force" -ne 1 ]]; then
      printf 'install: %s already exists and is not ours; use --force to replace.\n' "$target" >&2
      return 3
    fi
  fi
  if [[ "$runner_linked" -ne 1 ]]; then
    if [[ -d "$target" && ! -L "$target" ]]; then
      printf 'install: %s is a directory; refusing to replace it.\n' "$target" >&2
      return 3
    fi
    ln -sfn "$RUNNER" "$target" || return 1
    printf 'install: linked %s -> %s\n' "$target" "$RUNNER"
  fi

  # Put this installer itself on PATH so `inst_deputy.sh` runs from anywhere
  # (the script self-locates its source via the symlink, so cwd never matters).
  if [[ -f "$INSTALLER" ]]; then
    local self_target="$prefix/inst_deputy.sh"
    if [[ -d "$self_target" && ! -L "$self_target" ]]; then
      printf 'install: %s is a directory; not linking the installer.\n' "$self_target" >&2
    elif [[ "$(_resolve "$self_target")" == "$(_resolve "$INSTALLER")" ]]; then
      printf 'install: installer already linked: %s -> %s\n' "$self_target" "$INSTALLER"
    elif [[ ( -L "$self_target" || -e "$self_target" ) && "$force" -ne 1 ]]; then
      # Refuse to clobber a foreign file OR symlink without --force (mirrors the runner).
      printf 'install: %s already exists and is not ours; use --force to replace.\n' "$self_target" >&2
    else
      ln -sfn "$INSTALLER" "$self_target" || return 1
      printf 'install: linked installer %s -> %s\n' "$self_target" "$INSTALLER"
    fi
  fi
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) printf 'install: NOTE: %s is not on your PATH; add it to use `deputy` directly.\n' "$prefix" >&2 ;;
  esac

  # Install the orchestrator skill.
  local skills_dir="${DEPUTY_SKILLS_DIR:-$HOME/.claude/skills}"
  local skill_src="$SRC_DIR/skills/deputy" skill_dst="$skills_dir/deputy"
  if [[ -d "$skill_src" ]]; then
    mkdir -p "$skills_dir" || return 1
    if [[ -d "$skill_dst" && ! -L "$skill_dst" ]]; then
      printf 'install: %s is a directory; not replacing the skill.\n' "$skill_dst" >&2
    elif [[ -L "$skill_dst" && "$(_resolve "$skill_dst")" == "$(_resolve "$skill_src")" ]]; then
      printf 'install: skill already linked: %s -> %s\n' "$skill_dst" "$skill_src"
    else
      ln -sfn "$skill_src" "$skill_dst" || return 1
      printf 'install: linked skill %s -> %s\n' "$skill_dst" "$skill_src"
    fi
  fi
  # SessionStart hook: print guidance (V1 does not auto-edit Claude settings).
  printf 'install: SessionStart hook available at %s/hooks/session-start.sh (register it in your Claude settings to enable surfacing banners)\n' "$SRC_DIR"
}

cmd_init() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)"
  [[ -d "$dir" ]] || { printf 'install: not a directory: %s\n' "${1:-$PWD}" >&2; return 1; }
  [[ -f "$TEMPLATE" ]] || { printf 'install: template not found: %s\n' "$TEMPLATE" >&2; return 1; }

  # Bootstrap: ensure the `deputy` command + this installer + the skill are on
  # PATH (idempotent — prints "already linked" when present). This lets a first
  # run go straight to `init` without a separate `link` step. A foreign/locked
  # target only warns; it must not abort the per-repo seed below.
  printf 'install: ensuring the deputy command is on PATH...\n'
  cmd_link || printf 'install: NOTE: could not link the deputy command (see above); continuing with the repo seed.\n' >&2

  local backlog="$dir/BACKLOG.md"
  if [[ -e "$backlog" ]]; then
    printf 'install: BACKLOG.md already exists, leaving it untouched: %s\n' "$backlog"
  else
    cp "$TEMPLATE" "$backlog"
    printf 'install: seeded %s\n' "$backlog"
  fi

  local gi="$dir/.gitignore"
  if [[ -f "$gi" ]] && grep -qxF '.deputy/' "$gi"; then
    printf 'install: .deputy/ already ignored in %s\n' "$gi"
  else
    # Ensure we start on a fresh line if the file lacks a trailing newline.
    if [[ -f "$gi" && -s "$gi" && -n "$(tail -c1 "$gi")" ]]; then printf '\n' >> "$gi"; fi
    printf '.deputy/\n' >> "$gi"
    printf 'install: added .deputy/ to %s\n' "$gi"
  fi

  local f src dst
  for f in config protected; do
    src="$SRC_DIR/templates/$f"; dst="$dir/.deputy/$f"
    [[ -f "$src" ]] || continue
    mkdir -p "$dir/.deputy"
    if [[ -e "$dst" ]]; then
      printf 'install: %s already exists, leaving it\n' "$dst"
    else
      cp "$src" "$dst"; printf 'install: seeded %s\n' "$dst"
    fi
  done

  # Append Deputy task-intake guidance to CLAUDE.md so Claude records tasks to BACKLOG.md.
  local claude_md="$dir/CLAUDE.md"
  local sentinel="## Deputy: task intake"
  if [[ -f "$claude_md" ]] && grep -qF "$sentinel" "$claude_md"; then
    printf 'install: Deputy guidance already in %s\n' "$claude_md"
  else
    # Ensure we start on a fresh line if the file lacks a trailing newline.
    if [[ -f "$claude_md" && -s "$claude_md" && -n "$(tail -c1 "$claude_md")" ]]; then printf '\n' >> "$claude_md"; fi
    cat >> "$claude_md" <<'DEPUTY_GUIDANCE'

## Deputy: task intake

Whenever you discover unfinished work, planned features, bugs, or TODOs during a session,
record them in `BACKLOG.md` so Deputy can schedule and execute them automatically.

Add an item:
  deputy add "description"        # appends with auto-priority
  # or append a plain line to BACKLOG.md directly

Deputy processes `BACKLOG.md` on its next run; items are picked by priority (P0 > P1 > P2 > P3 > P4); bare items default to P3 at numbering (P4 is the lowest lane).
DEPUTY_GUIDANCE
    printf 'install: appended Deputy guidance to %s\n' "$claude_md"
  fi

  # Enable the cron heartbeat for this project (same as 'inst_deputy.sh cron' run from $dir).
  if DEPUTY_ROOT="$dir" bash "$RUNNER" cron --ensure 2>/dev/null; then
    printf 'install: cron heartbeat enabled for %s\n' "$dir"
  else
    printf 'install: NOTE: could not enable cron heartbeat; run inst_deputy.sh cron from %s to enable it manually\n' "$dir" >&2
  fi
}

main() {
  local cmd="${1:-link}"
  case "$cmd" in
    link)          shift || true; cmd_link "$@" ;;
    init)          shift || true; cmd_init "$@" ;;
    cron)          shift || true; bash "$RUNNER" cron --ensure ;;
    help|-h|--help) usage ;;
    --*)           cmd_link "$@" ;;   # allow `inst_deputy.sh --prefix DIR` / `--force`
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
