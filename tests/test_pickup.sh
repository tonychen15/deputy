#!/usr/bin/env bash
# tests/test_pickup.sh — 'deputy pickup <id>' brings up ONE attention task and ACTS on it:
# failed/cancelled/deferred/paused → waiting (requeue); surfaced proposed → waiting (approve,
# marker cleared); surfaced needs-input → stays surfaced (points to /deputy); surfaced
# ready-to-merge → merges into the default branch (item done). Validation for bad/wrong states.
source "$(dirname "$0")/lib.sh"
D() { bash "$DEPUTY" "$@"; }
_id() { D list | grep -F "$1" | grep -oE '#[0-9]+' | tr -d '#' | head -1; }

# ── requeue transitions: failed / cancelled / deferred / paused → waiting ──────
setup_repo
for st in failed cancelled deferred paused; do
  D add "task for $st" >/dev/null; tid="$(_id "task for $st")"
  D set "#$tid" "$st" >/dev/null
  out="$(D pickup "#$tid")"; rc=$?
  assert_eq "$rc" "0" "pickup $st exits 0"
  assert_contains "$out" "→ waiting" "pickup $st reports requeue"
  assert_contains "$(D list waiting)" "task for $st" "pickup $st: item is now waiting"
done

# ── surfaced · proposed → waiting (approve), proposed marker cleared ───────────
setup_repo
D add "worker proposal item" >/dev/null; pid="$(_id 'worker proposal item')"
printf 'proposed\n' > "$DEPUTY_ROOT/.deputy/proposed-$pid"
D set "#$pid" surfaced >/dev/null
out="$(D pickup "#$pid")"; rc=$?
assert_eq "$rc" "0" "pickup proposed exits 0"
assert_contains "$out" "approved proposal" "pickup proposed reports approval"
assert_contains "$(D list waiting)" "worker proposal item" "pickup proposed: item now waiting"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$pid" && echo present || echo cleared)" "cleared" "pickup proposed: marker cleared"

# ── surfaced · needs-input → stays surfaced, points to /deputy ─────────────────
setup_repo
D add "needs a human decision" >/dev/null; nid="$(_id 'needs a human decision')"
D set "#$nid" surfaced >/dev/null
out="$(D pickup "#$nid")"; rc=$?
assert_eq "$rc" "0" "pickup needs-input exits 0"
assert_contains "$out" "/deputy" "pickup needs-input points to /deputy"
assert_contains "$(D list surfaced)" "needs a human decision" "pickup needs-input: item stays surfaced"

# ── surfaced · ready-to-merge → merges into the default branch, item done ──────
setup_repo
git -C "$DEPUTY_ROOT" init -q -b master
git -C "$DEPUTY_ROOT" config user.email t@t; git -C "$DEPUTY_ROOT" config user.name t
git -C "$DEPUTY_ROOT" add -A; git -C "$DEPUTY_ROOT" commit -q -m init
D add "mergeable feature" >/dev/null; mid="$(_id 'mergeable feature')"
slug="$(D slug "$mid")"
# build the branch with a feature file (in a throwaway worktree so master is untouched)
git -C "$DEPUTY_ROOT" worktree add -q "$DEPUTY_ROOT/wt-tmp" -b "deputy/$slug"
echo feat > "$DEPUTY_ROOT/wt-tmp/feature-$mid.txt"
git -C "$DEPUTY_ROOT/wt-tmp" add -A; git -C "$DEPUTY_ROOT/wt-tmp" commit -q -m "feat $mid"
git -C "$DEPUTY_ROOT" worktree remove "$DEPUTY_ROOT/wt-tmp"
D set "#$mid" surfaced --ready-merge --branch="deputy/$slug" >/dev/null
out="$(D pickup "#$mid")"; rc=$?
assert_eq "$rc" "0" "pickup ready-merge exits 0"
assert_eq "$(git -C "$DEPUTY_ROOT" show master:feature-$mid.txt 2>/dev/null || echo MISSING)" "feat" "pickup ready-merge: change landed on master"
assert_contains "$(D list)" "+[#$mid]" "pickup ready-merge: item marked done"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/ready-merge-$mid" && echo present || echo cleared)" "cleared" "pickup ready-merge: marker cleared"

# ── ready-to-merge but NOT on the default branch → no merge, actionable message ─
setup_repo
git -C "$DEPUTY_ROOT" init -q -b master
git -C "$DEPUTY_ROOT" config user.email t@t; git -C "$DEPUTY_ROOT" config user.name t
git -C "$DEPUTY_ROOT" add -A; git -C "$DEPUTY_ROOT" commit -q -m init
D add "offbranch feature" >/dev/null; oid="$(_id 'offbranch feature')"
oslug="$(D slug "$oid")"
git -C "$DEPUTY_ROOT" worktree add -q "$DEPUTY_ROOT/wt-tmp" -b "deputy/$oslug"
echo feat > "$DEPUTY_ROOT/wt-tmp/feature-$oid.txt"
git -C "$DEPUTY_ROOT/wt-tmp" add -A; git -C "$DEPUTY_ROOT/wt-tmp" commit -q -m "feat $oid"
git -C "$DEPUTY_ROOT" worktree remove "$DEPUTY_ROOT/wt-tmp"
D set "#$oid" surfaced --ready-merge --branch="deputy/$oslug" >/dev/null
git -C "$DEPUTY_ROOT" checkout -q -b sidebranch     # move OFF the default branch
out="$(D pickup "#$oid")"; rc=$?
assert_eq "$rc" "1" "pickup off-default exits 1 (no merge)"
assert_contains "$out" "not on the default branch" "pickup off-default: explains why + manual command"
assert_eq "$(git -C "$DEPUTY_ROOT" show master:feature-$oid.txt 2>/dev/null || echo MISSING)" "MISSING" "pickup off-default: nothing merged to master"

# ── validation ────────────────────────────────────────────────────────────────
setup_repo
D pickup            >/dev/null 2>&1; assert_eq "$?" "2" "pickup with no id exits 2"
D pickup abc        >/dev/null 2>&1; assert_eq "$?" "2" "pickup non-numeric id exits 2"
D pickup 99999      >/dev/null 2>&1; assert_eq "$?" "1" "pickup unknown id exits 1"
D add "a plain waiting task" >/dev/null; wid="$(_id 'a plain waiting task')"
D pickup "#$wid"    >/dev/null 2>&1; assert_eq "$?" "2" "pickup a waiting (non-attention) task exits 2"
