#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
HOOK="$REPO/hooks/session-start.sh"
setup_repo
bash "$DEPUTY" add "needs your call" --p0
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" surfaced
out="$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$HOOK")"
assert_contains "$out" "needs your call" "hook lists surfaced item"
assert_contains "$out" "deputy watch" "hook points to watch"

# No surfaced items -> quiet (no banner noise)
setup_repo
out="$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$HOOK")"
assert_eq "$out" "" "hook silent when nothing surfaced"
