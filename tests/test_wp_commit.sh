#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
WT="$(mktemp -d)"; export DEPUTY_WT="$WT"
git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t
echo seed > "$WT/seed"; git -C "$WT" add -A; git -C "$WT" commit -qm seed

bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" set-step t --step 1
echo "hello" > "$WT/new.txt"           # an UNDECLARED change in the worktree
bash "$DEPUTY" commit t --summary "did one"

j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.steps[0].status' "$j")" "succeeded" "step flipped to succeeded"
assert_eq "$(jq -r '.current_step==null' "$j")" "true"   "current cleared"
assert_eq "$(jq -r '.steps[0].actual_result.summary' "$j")" "did one" "summary recorded"
sha="$(jq -r '.steps[0].actual_result.artifacts[0].step_commit' "$j")"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$sha" "recorded SHA = HEAD"
assert_contains "$(git -C "$WT" show --stat HEAD)" "new.txt" "staged all changes"
assert_eq "$(bash "$DEPUTY" resume t)" "" "resume empty after commit"
rm -rf "$WT"
