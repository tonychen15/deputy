#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

bash "$DEPUTY" add "First task"
bash "$DEPUTY" add "Urgent one" --p0
bash "$DEPUTY" add "Important one" --p2

out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting||First task"       "add untagged"
assert_contains "$out" "waiting|P0|Urgent one"     "add --p0"
assert_contains "$out" "waiting|P2|Important one"  "add --p2"

# Dedup by description (no duplicate even with a different flag).
bash "$DEPUTY" add "First task" --p1
n="$(bash "$DEPUTY" list | grep -c 'First task')"
assert_eq "$n" "1" "add dedups by description"

# The legend survives an add.
assert_eq "$(grep -c 'LEGEND' "$DEPUTY_ROOT/BACKLOG.md")" "1" "legend intact after add"

# Unknown flags are rejected, not absorbed into the description.
bash "$DEPUTY" add "real task" --p3 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects unknown flag"
assert_eq "$(bash "$DEPUTY" list | grep -c -- '--p3')" "0" "unknown flag not absorbed"

# Bare multi-word descriptions still join.
bash "$DEPUTY" add Buy the milk
assert_contains "$(bash "$DEPUTY" list)" "waiting||Buy the milk" "bare multi-word add joins"

# Descriptions that collide with the line grammar are rejected (would corrupt state).
bash "$DEPUTY" add "@ ping the oncall" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects description starting with status prefix + space"
bash "$DEPUTY" add "[P1] looks like a tag" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects description starting with priority tag"
n="$(bash "$DEPUTY" list | grep -c 'oncall\|looks like a tag')"
assert_eq "$n" "0" "rejected descriptions are not written"
# A description merely CONTAINING @ (not a leading prefix+space) is still allowed.
bash "$DEPUTY" add "email @bob about it"
assert_contains "$(bash "$DEPUTY" list)" "waiting||email @bob about it" "non-prefix @ still allowed"
