#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" plan t --step 2 --purpose "two"

assert_contains "$(bash "$DEPUTY" resume t)" "1|one" "resume points at first pending"

bash "$DEPUTY" set-step t --step 1 --expected "done looks like X"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.current_step' "$j")" "1" "current_step set to 1"
assert_eq "$(jq -r '.steps[0].status' "$j")" "in_progress" "step 1 active"
assert_eq "$(jq -r '.steps[0].expected_result' "$j")" "done looks like X" "expected recorded"
assert_contains "$(bash "$DEPUTY" resume t)" "1|one" "resume returns the in_progress step"
