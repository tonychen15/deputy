#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] first' '[P1] second' >> "$DEPUTY_ROOT/BACKLOG.md"

# A live "owner" process to attribute a claim to.
sleep 300 & LIVE=$!

bash "$DEPUTY" claim "[P0] first" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim succeeds when free"
assert_contains "$(bash "$DEPUTY" list)" "running|P0|first" "claimed item is running"
[[ -f "$DEPUTY_ROOT/.deputy/$LIVE.claim" ]] && r=yes || r=no
assert_eq "$r" "yes" "claim file written"
assert_eq "$(cat "$DEPUTY_ROOT/.deputy/$LIVE.claim")" "@[P0] first" "claim file holds running line"

# Second claim refused while a live claim exists (serial).
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] second" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "3" "second claim refused (serial guard)"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|second" "second item still waiting"

kill "$LIVE" "$LIVE2" 2>/dev/null

# A paused item can be claimed (resuming after preemption).
setup_repo
printf '^[P0] paused checkpoint\n' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE3=$!
bash "$DEPUTY" claim "^[P0] paused checkpoint" --pid "$LIVE3"; rc=$?
assert_eq "$rc" "0" "claim from paused state"
assert_contains "$(bash "$DEPUTY" list)" "running|P0|paused checkpoint" "paused→running on claim"
kill "$LIVE3" 2>/dev/null
