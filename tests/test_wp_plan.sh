#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "first step"
bash "$DEPUTY" plan t --step 2 --purpose "second step"

out="$(bash "$DEPUTY" steps t)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "two steps listed"
assert_contains "$out" "1|pending|first step"  "step 1 pending"
assert_contains "$out" "2|pending|second step" "step 2 pending"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.steps[0].status' "$j")" "pending" "appended as pending"
assert_eq "$(jq -r '.steps|length' "$j")" "2" "two steps stored"
