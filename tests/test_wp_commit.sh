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

# ── no-change commit must fail ─────────────────────────────────────────────
setup_repo
WT2="$(mktemp -d)"; export DEPUTY_WT="$WT2"
git -C "$WT2" init -q; git -C "$WT2" config user.email t@t; git -C "$WT2" config user.name t
echo seed > "$WT2/seed"; git -C "$WT2" add -A; git -C "$WT2" commit -qm seed
before_sha="$(git -C "$WT2" rev-parse HEAD)"

bash "$DEPUTY" start t2 "goal"
bash "$DEPUTY" plan  t2 --step 1 --purpose "no-op step"
bash "$DEPUTY" set-step t2 --step 1
# Make NO change in the worktree — commit should fail
j2="$DEPUTY_ROOT/.deputy/waypoints/t2/waypoint.json"
set +e
out2="$(bash "$DEPUTY" commit t2 --summary "empty" 2>&1)"; rc2=$?
set -e
assert_eq "$rc2" "1" "no-change commit exits non-zero"
assert_contains "$out2" "no changes staged" "error mentions no changes staged"
assert_eq "$(jq -r '.steps[0].status' "$j2")" "in_progress" "step stays in_progress"
assert_eq "$(jq -r '.current_step' "$j2")" "1" "current_step still set"
assert_eq "$(git -C "$WT2" rev-parse HEAD)" "$before_sha" "HEAD unchanged after failed commit"
rm -rf "$WT2"

# ── --allow-empty produces a new commit and marks the step succeeded ───────
setup_repo
WT3="$(mktemp -d)"; export DEPUTY_WT="$WT3"
git -C "$WT3" init -q; git -C "$WT3" config user.email t@t; git -C "$WT3" config user.name t
echo seed > "$WT3/seed"; git -C "$WT3" add -A; git -C "$WT3" commit -qm seed
before_sha3="$(git -C "$WT3" rev-parse HEAD)"

bash "$DEPUTY" start t3 "goal"
bash "$DEPUTY" plan  t3 --step 1 --purpose "empty step"
bash "$DEPUTY" set-step t3 --step 1
# Make NO change in the worktree — but pass --allow-empty
j3="$DEPUTY_ROOT/.deputy/waypoints/t3/waypoint.json"
bash "$DEPUTY" commit t3 --summary "noop" --allow-empty
assert_eq "$(jq -r '.steps[0].status' "$j3")" "succeeded" "--allow-empty step succeeded"
after_sha3="$(git -C "$WT3" rev-parse HEAD)"
[[ "$after_sha3" != "$before_sha3" ]] || { printf 'FAIL: --allow-empty did not advance HEAD\n' >&2; TESTS_FAILED=$((TESTS_FAILED+1)); }
TESTS_RUN=$((TESTS_RUN+1))
sha3="$(jq -r '.steps[0].actual_result.artifacts[0].step_commit' "$j3")"
assert_eq "$sha3" "$after_sha3" "--allow-empty recorded new SHA"
rm -rf "$WT3"
