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

# guard: plan rejects duplicate step id
setup_repo
bash "$DEPUTY" start g "goal"; bash "$DEPUTY" plan g --step 1 --purpose one
bash "$DEPUTY" plan g --step 1 --purpose dup 2>/dev/null && rc=0 || rc=$?
assert_eq "$rc" "1" "plan rejects duplicate step id"

# guard: done rejects when steps not all succeeded
bash "$DEPUTY" done g 2>/dev/null && rc=0 || rc=$?
assert_eq "$rc" "1" "done rejects when steps not all succeeded"

# at-most-one in_progress: set-step to step 2 demotes step 1 to pending
bash "$DEPUTY" plan g --step 2 --purpose two
bash "$DEPUTY" set-step g --step 1
bash "$DEPUTY" set-step g --step 2
j="$DEPUTY_ROOT/.deputy/waypoints/g/waypoint.json"
assert_eq "$(jq -r '[.steps[]|select(.status=="in_progress")]|length' "$j")" "1" "at most one in_progress"
assert_eq "$(jq -r '.current_step' "$j")" "2" "current_step is the latest set-step"
