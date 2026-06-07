#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Mixed priorities + a running item that must be ignored.
printf '%s\n' 'untagged old' '[P2] important' '@ [P0] already running' '[P1] urgent' '[P0] top' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P0] top" "pick chooses highest priority waiting"

# FIFO within a lane: two P1 waiting -> first in file wins.
setup_repo
printf '%s\n' '[P1] first urgent' '[P1] second urgent' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P1] first urgent" "pick FIFO within lane"

# Untagged is the lowest lane but still picked when nothing else waits.
setup_repo
printf '%s\n' '@ [P0] running' 'plain waiting' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "plain waiting" "pick falls back to untagged"

# Nothing waiting -> empty output, exit 0.
setup_repo
printf '%s\n' '# done item' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" pick)"; rc=$?
assert_eq "$out" "" "pick empty when nothing waits"
assert_eq "$rc" "0" "pick exits 0 when empty"
