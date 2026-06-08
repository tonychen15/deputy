#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] a' 'b' '@ c' '? [P1] d' '# e' '! f' '~ g' '% h' '= i' '^[P2] j' >> "$DEPUTY_ROOT/BACKLOG.md"

out="$(bash "$DEPUTY" status)"
assert_contains "$out" "waiting:  2"   "status waiting count"
assert_contains "$out" "triaging: 1"   "status triaging count"
assert_contains "$out" "running:  1"   "status running count"
assert_contains "$out" "surfaced: 1"   "status surfaced count"
assert_contains "$out" "done:     1"   "status done count"
assert_contains "$out" "failed:   1"   "status failed count"
assert_contains "$out" "cancelled: 1"  "status cancelled count"
assert_contains "$out" "duplicate: 1"  "status duplicate count"
assert_contains "$out" "paused:   1"   "status paused count"
