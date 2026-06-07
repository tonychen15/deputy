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
