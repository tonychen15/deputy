#!/usr/bin/env bash
# Deputy SessionStart hook: surface items needing input + a one-line digest.
# Prints nothing if there is nothing surfaced (no banner noise).
set -uo pipefail
ROOT="${DEPUTY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DEP="$(command -v deputy 2>/dev/null || true)"
if [[ -z "$DEP" ]]; then
  DEP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../bin && pwd)/deputy.sh"
fi
[[ -x "$DEP" && -f "$ROOT/BACKLOG.md" ]] || exit 0

surfaced="$(DEPUTY_ROOT="$ROOT" "$DEP" list | awk -F'|' '$1=="surfaced"{out=$3; for(i=4;i<=NF;i++) out=out"|"$i; print "  ? " out}')"
[[ -n "$surfaced" ]] || exit 0

counts="$(DEPUTY_ROOT="$ROOT" "$DEP" status | tr '\n' ' ')"
printf '⚠️  Deputy: items need your input\n%s\n[%s]\nRun: deputy review\n' "$surfaced" "$counts"
