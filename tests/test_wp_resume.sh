#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
WT="$(mktemp -d)"; export DEPUTY_WT="$WT"
git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t
echo seed > "$WT/seed"; git -C "$WT" add -A; git -C "$WT" commit -qm seed

bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" plan t --step 2 --purpose "two"
bash "$DEPUTY" set-step t --step 1; echo a > "$WT/a"; bash "$DEPUTY" commit t --summary "one done"
# "interruption": step 2 set active but never committed
bash "$DEPUTY" set-step t --step 2; echo b-partial > "$WT/b"

assert_contains "$(bash "$DEPUTY" resume t)" "2|two" "resume continues at step 2"
bash "$DEPUTY" commit t --summary "two done"; bash "$DEPUTY" done t
assert_eq "$(bash "$DEPUTY" resume t)" "" "nothing left to resume"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.status' "$j")" "completed" "task completed"
assert_eq "$(jq -r '[.steps[]|select(.status=="succeeded")]|length' "$j")" "2" "both steps succeeded"
rm -rf "$WT"
