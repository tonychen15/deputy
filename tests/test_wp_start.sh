#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

bash "$DEPUTY" start demo-1 "Build the thing"
j="$DEPUTY_ROOT/.deputy/waypoints/demo-1/waypoint.json"
assert_eq "$([[ -f "$j" ]] && echo yes || echo no)" "yes" "start creates waypoint.json"
assert_eq "$(jq -r .task_id "$j")" "demo-1"        "task_id set"
assert_eq "$(jq -r .goal "$j")"    "Build the thing" "goal set"
assert_eq "$(jq -r .status "$j")"  "in_progress"    "status in_progress"
assert_eq "$(jq -r '.steps|length' "$j")" "0"       "no steps yet"
assert_eq "$(jq -r '.current_step==null' "$j")" "true" "no current step"
assert_eq "$(jq -r '.note' "$j")" "" "note empty on create"
assert_eq "$(jq -r '.created_at!=null and .updated_at!=null' "$j")" "true" "timestamps set"

assert_contains "$(cat "$DEPUTY_ROOT/.deputy/waypoints/demo-1/STATUS.md")" "Build the thing" "STATUS.md has goal"

bash "$DEPUTY" plan demo-1 --step 1 --purpose "p" >/dev/null 2>&1 || true
bash "$DEPUTY" start demo-1 "DIFFERENT goal"
assert_eq "$(jq -r .goal "$j")" "Build the thing" "start idempotent (no clobber)"

bash "$DEPUTY" done demo-1
assert_eq "$(jq -r .status "$j")" "completed" "done marks completed"
assert_eq "$(jq -r '.current_step==null' "$j")" "true" "done clears current_step"

assert_contains "$(bash "$DEPUTY" _wp_show demo-1)" "\"task_id\": \"demo-1\"" "_wp_show prints the json"
