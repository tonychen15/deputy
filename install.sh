#!/usr/bin/env bash
# install.sh — install the Deputy runner (Plan 1 MVP).
#
#   install.sh [link] [--prefix DIR] [--force]   symlink `deputy` into DIR (default: $HOME/.local/bin)
#   install.sh init [DIR]                         seed BACKLOG.md, .deputy/, and CLAUDE.md guidance in DIR (default: cwd)
#   install.sh help
#
# `link` puts the `deputy` command on your PATH; the runner resolves its target
# repo at call time ($DEPUTY_ROOT, else the git toplevel of your cwd). `init`
# prepares a specific repo's queue file.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SRC_DIR/bin/deputy.sh"
TEMPLATE="$SRC_DIR/templates/BACKLOG.md"

usage() {
  cat <<EOF
usage:
  install.sh [link] [--prefix DIR] [--force]   symlink 'deputy' into DIR (default: \$HOME/.local/bin)
  install.sh init [DIR]                         seed BACKLOG.md, .deputy/, and CLAUDE.md guidance in DIR (default: cwd)
  install.sh cron                               run 'deputy cron --ensure' (opt-in safety-net)
  install.sh help
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
  mkdir -p "$prefix"
  local target="$prefix/deputy"
  if [[ -L "$target" || -e "$target" ]]; then
    if [[ "$(readlink -f "$target" 2>/dev/null)" == "$(readlink -f "$RUNNER")" ]]; then
      printf 'install: already linked: %s -> %s\n' "$target" "$RUNNER"
      return 0
    fi
    if [[ "$force" -ne 1 ]]; then
      printf 'install: %s already exists and is not ours; use --force to replace.\n' "$target" >&2
      return 3
    fi
  fi
  if [[ -d "$target" && ! -L "$target" ]]; then
    printf 'install: %s is a directory; refusing to replace it.\n' "$target" >&2
    return 3
  fi
  ln -sfn "$RUNNER" "$target"
  printf 'install: linked %s -> %s\n' "$target" "$RUNNER"
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) printf 'install: NOTE: %s is not on your PATH; add it to use `deputy` directly.\n' "$prefix" >&2 ;;
  esac

  # Install the orchestrator skill.
  local skills_dir="${DEPUTY_SKILLS_DIR:-$HOME/.claude/skills}"
  local skill_src="$SRC_DIR/skills/deputy" skill_dst="$skills_dir/deputy"
  if [[ -d "$skill_src" ]]; then
    mkdir -p "$skills_dir"
    if [[ -d "$skill_dst" && ! -L "$skill_dst" ]]; then
      printf 'install: %s is a directory; not replacing the skill.\n' "$skill_dst" >&2
    elif [[ -L "$skill_dst" && "$(readlink -f "$skill_dst" 2>/dev/null)" == "$(readlink -f "$skill_src")" ]]; then
      printf 'install: skill already linked: %s -> %s\n' "$skill_dst" "$skill_src"
    else
      ln -sfn "$skill_src" "$skill_dst"
      printf 'install: linked skill %s -> %s\n' "$skill_dst" "$skill_src"
    fi
  fi
  # SessionStart hook: print guidance (V1 does not auto-edit Claude settings).
  printf 'install: SessionStart hook available at %s/hooks/session-start.sh (register it in your Claude settings to enable surfacing banners)\n' "$SRC_DIR"
}

cmd_init() {
  local dir="${1:-$PWD}"
  [[ -d "$dir" ]] || { printf 'install: not a directory: %s\n' "$dir" >&2; return 1; }
  [[ -f "$TEMPLATE" ]] || { printf 'install: template not found: %s\n' "$TEMPLATE" >&2; return 1; }

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

Deputy processes `BACKLOG.md` on its next run; items are picked by priority (P0 > P1 > P2 > untagged).
DEPUTY_GUIDANCE
    printf 'install: appended Deputy guidance to %s\n' "$claude_md"
  fi
}

main() {
  local cmd="${1:-link}"
  case "$cmd" in
    link)          shift || true; cmd_link "$@" ;;
    init)          shift || true; cmd_init "$@" ;;
    cron)          shift || true; bash "$RUNNER" cron --ensure ;;
    help|-h|--help) usage ;;
    --*)           cmd_link "$@" ;;   # allow `install.sh --prefix DIR` / `--force`
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
