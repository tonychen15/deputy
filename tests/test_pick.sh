#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Mixed priorities + a running item that must be ignored.
# After allocation (triggered by pick/list), items get [#N] tags.
printf '%s\n' 'untagged old' '[P2] important' '@ [P0] already running' '[P1] urgent' '[P0] top' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null   # trigger allocation
pick_out="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out" "[P0]" "pick chooses highest priority waiting"
assert_contains "$pick_out" "top"  "pick chooses 'top' item"

# FIFO within a lane: two P1 waiting -> first in file wins.
setup_repo
printf '%s\n' '[P1] first urgent' '[P1] second urgent' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pick_out2="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out2" "[P1]"         "pick FIFO: P1 line"
assert_contains "$pick_out2" "first urgent" "pick FIFO within lane"

# Untagged is the lowest lane but still picked when nothing else waits.
setup_repo
printf '%s\n' '@ [P0] running' 'plain waiting' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pick_out3="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out3" "plain waiting" "pick falls back to untagged"

# Nothing waiting -> empty output, exit 0.
setup_repo
printf '%s\n' '# done item' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" pick)"; rc=$?
assert_eq "$out" "" "pick empty when nothing waits"
assert_eq "$rc" "0" "pick exits 0 when empty"

# Paused items are pickable and compete by priority/FIFO.
setup_repo
printf '%s\n' '^[P1] paused job' '[P2] waiting job' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pick_out4="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out4" "[P1]"       "pick prefers paused P1 over waiting P2 (priority)"
assert_contains "$pick_out4" "paused job" "pick prefers paused P1 item"

# Paused item at same priority as waiting: FIFO (file position) wins.
setup_repo
printf '%s\n' '[P0] waiting top' '^[P0] paused top' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pick_out5="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out5" "[P0]"        "pick FIFO within lane: P0 item"
assert_contains "$pick_out5" "waiting top" "pick FIFO within lane: waiting before paused"
