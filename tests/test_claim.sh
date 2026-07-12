#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] first' '[P1] second' >> "$DEPUTY_ROOT/BACKLOG.md"

# Trigger allocation so lines get [#N] tags before we use them
bash "$DEPUTY" list >/dev/null
first_line="$(bash "$DEPUTY" pick)"   # [P0][#1] first

# A live "owner" process to attribute a claim to.
sleep 300 & LIVE=$!

bash "$DEPUTY" claim "$first_line" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim succeeds when free"
assert_contains "$(bash "$DEPUTY" list)" "@[#"          "claimed item is running"
assert_contains "$(bash "$DEPUTY" list)" "first"        "claimed item description present"
[[ -f "$DEPUTY_ROOT/.deputy/$LIVE.claim" ]] && r=yes || r=no
assert_eq "$r" "yes" "claim file written"
running_form="$(cat "$DEPUTY_ROOT/.deputy/$LIVE.claim")"
assert_contains "$running_form" "@[#1][P0]" "claim file holds running line"
assert_contains "$running_form" "first" "claim file has description"

# Second claim refused while a live claim exists (serial).
# list now outputs BACKLOG.md format, so the line can be passed directly to claim.
second_line="$(bash "$DEPUTY" list | grep 'second')"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "$second_line" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "3" "second claim refused (serial guard)"
assert_contains "$(bash "$DEPUTY" list)" "[P1]"  "second item still waiting"
assert_contains "$(bash "$DEPUTY" list)" "second" "second item still present"

kill "$LIVE" "$LIVE2" 2>/dev/null

# A paused item can be claimed (resuming after preemption).
setup_repo
printf '^[P0] paused checkpoint\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
paused_line="$(bash "$DEPUTY" pick)"   # ^[P0][#1] paused checkpoint
sleep 300 & LIVE3=$!
bash "$DEPUTY" claim "$paused_line" --pid "$LIVE3"; rc=$?
assert_eq "$rc" "0" "claim from paused state"
assert_contains "$(bash "$DEPUTY" list)" "@[#"          "paused→running on claim"
assert_contains "$(bash "$DEPUTY" list)" "paused checkpoint" "paused checkpoint description preserved"
kill "$LIVE3" 2>/dev/null
