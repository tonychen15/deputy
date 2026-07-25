#!/usr/bin/env bash
# tests/test_merge_dirty.sh — #111: the runner auto-merges a ready branch even when the main
# tree has UNRELATED work in progress.
#
# Deputy used to require `git status --porcelain` to be completely EMPTY, which is far stricter
# than git itself: it surfaced a "merge blocked, merge it by hand" note for merges git would
# have performed happily. The rule is now git's own actual rule —
#   * the INDEX must be clean (ANY staged change makes the ort strategy refuse, even a
#     non-overlapping one), and
#   * the paths the merge WRITES must be disjoint from the human's dirty paths.
# Overlapping or staged changes cannot merge right now, but they are NOT put in the human's
# pickup queue either (#112): they PARK in the non-attention 'pending-merge' state and the
# runner retries them on a later tick. merge_dirty_disjoint=0 restores the strict rule.
#
# The mock orchestrator commits two files on the branch: feature-<id>.txt (new) and an append
# to shared.txt (tracked at init) — so both the "merge creates this path" and the "merge
# rewrites this tracked path" overlap cases can be exercised.
source "$(dirname "$0")/lib.sh"

# $1 = merge_dirty_disjoint value ("" = leave unset, i.e. default-on)
_md_setup() {  # sets MDR (repo), MDM (mock), MDID (item id)
  MDR="$(mktemp -d)"; MDM="$(mktemp)"     # mock is OUTSIDE the repo
  mkdir -p "$MDR/.deputy"; cp "$REPO/templates/BACKLOG.md" "$MDR/BACKLOG.md"
  { printf 'auto_merge=1\nwatchdog_mins=0\n'
    [[ -n "$1" ]] && printf 'merge_dirty_disjoint=%s\n' "$1"; } > "$MDR/.deputy/config"
  git -C "$MDR" init -q -b master; git -C "$MDR" config user.email t@t; git -C "$MDR" config user.name t
  printf 'original frontend\n' > "$MDR/frontend.txt"      # the human's unrelated file
  printf 'shared base\n'       > "$MDR/shared.txt"        # touched by BOTH sides
  git -C "$MDR" add -A; git -C "$MDR" commit -q -m init
  cat > "$MDM" <<MOCK
#!/usr/bin/env bash
item="\$1"; root="$MDR"; DEP="$DEPUTY"
id=\$(printf '%s' "\$item" | grep -oE '#[0-9]+' | head -1 | tr -d '#'); slug="mdtest-\$id"
git -C "\$root" worktree add -q "\$root/.deputy/wt" -b "deputy/\$slug" 2>/dev/null
echo "feat \$id" > "\$root/.deputy/wt/feature-\$id.txt"
mkdir -p "\$root/.deputy/wt/sub"; echo "nested \$id" > "\$root/.deputy/wt/sub/nested-\$id.txt"
echo "branch line" >> "\$root/.deputy/wt/shared.txt"
git -C "\$root/.deputy/wt" add -A; git -C "\$root/.deputy/wt" commit -q -m "feat \$id"
mkdir -p "\$root/.deputy/waypoints/\$slug"; printf '{"steps":[{"status":"succeeded"}]}' > "\$root/.deputy/waypoints/\$slug/waypoint.json"
DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" surfaced --ready-merge --branch="deputy/\$slug" >/dev/null 2>&1
DEPUTY_ROOT="\$root" bash "\$DEP" wt-remove >/dev/null 2>&1
MOCK
  chmod +x "$MDM"
  DEPUTY_NO_AUTORUN=1 DEPUTY_ROOT="$MDR" bash "$DEPUTY" add "mdtest feature" --p0 >/dev/null
  MDID="$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list | grep -F 'mdtest feature' | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
}
_md_run() { DEPUTY_ORCHESTRATOR_CMD="$MDM" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_ROOT="$MDR" timeout 40 bash "$DEPUTY" run --once >"$MDR/.runout" 2>&1; }
_md_merged() { git -C "$MDR" show "master:feature-$MDID.txt" 2>/dev/null || echo MISSING; }

# A) THE CASE THIS ITEM EXISTS FOR — an unrelated tracked file is dirty (unstaged).
#    The merge writes feature-<id>.txt and shared.txt; frontend.txt is disjoint → merge proceeds.
_md_setup ""
printf 'work in progress\n' >> "$MDR/frontend.txt"
_md_run
assert_eq "$(_md_merged)" "feat $MDID" "dirty-but-disjoint main tree: branch IS auto-merged"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list)" "+[#$MDID]" "dirty-but-disjoint: item marked done"
# The human's work must survive the merge untouched...
assert_contains "$(cat "$MDR/frontend.txt")" "work in progress" "dirty-but-disjoint: human's uncommitted work preserved in the worktree"
# ...and must NOT have been swept into the merge commit.
assert_eq "$(git -C "$MDR" show master:frontend.txt)" "original frontend" "dirty-but-disjoint: human's work NOT captured in the merge commit"
assert_eq "$(git -C "$MDR" status --porcelain -- frontend.txt)" " M frontend.txt" "dirty-but-disjoint: frontend.txt still shows as modified afterwards"

# B) Untracked-only dirt never blocks a merge (git only objects if the merge creates that path).
_md_setup ""
printf 'scratch\n' > "$MDR/notes-scratch.txt"
_md_run
assert_eq "$(_md_merged)" "feat $MDID" "untracked-only dirt: branch IS auto-merged"
assert_eq "$(test -f "$MDR/notes-scratch.txt" && echo present || echo GONE)" "present" "untracked-only dirt: untracked file left alone"

# C) A STAGED change blocks the merge even though it does not overlap — git's ort strategy
#    refuses any merge with a dirty index, so deputy must not attempt it.
_md_setup ""
printf 'staged work\n' >> "$MDR/frontend.txt"; git -C "$MDR" add frontend.txt
_md_run
assert_eq "$(_md_merged)" "MISSING" "staged change: NOT merged (git refuses a dirty index)"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "staged change: item PARKED in pending-merge, not put in the human's queue"

# D) OVERLAP on a tracked file the merge rewrites → must refuse (merging would clobber the work).
_md_setup ""
printf 'human edit\n' >> "$MDR/shared.txt"
_md_run
assert_eq "$(_md_merged)" "MISSING" "overlapping tracked file: NOT merged"
assert_contains "$(cat "$MDR/shared.txt")" "human edit" "overlapping tracked file: human's edit preserved"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "overlapping tracked file: item PARKED in pending-merge"

# E) OVERLAP where an UNTRACKED file occupies a path the merge would create → must refuse.
_md_setup ""
printf 'mine\n' > "$MDR/feature-$MDID.txt"
_md_run
assert_eq "$(git -C "$MDR" show "master:feature-$MDID.txt" 2>/dev/null || echo MISSING)" "MISSING" "untracked file in the merge's path: NOT merged"
assert_eq "$(cat "$MDR/feature-$MDID.txt")" "mine" "untracked file in the merge's path: human's file untouched"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "untracked file in the merge's path: item PARKED in pending-merge"

# F) merge_dirty_disjoint=0 restores the strict pristine-tree rule.
_md_setup 0
printf 'work in progress\n' >> "$MDR/frontend.txt"
_md_run
assert_eq "$(_md_merged)" "MISSING" "merge_dirty_disjoint=0: dirty tree blocks the merge (strict rule)"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "merge_dirty_disjoint=0: item PARKED in pending-merge"

# H) OVERLAP on an untracked file NESTED in an untracked directory → must still refuse.
#    `git status --porcelain` defaults to -unormal, which collapses these into 'sub/' — that
#    would never match the merge-affected path 'sub/nested-<id>.txt' in the exact-match
#    intersection, so the overlap would slip through the precheck. -uall is what catches it.
_md_setup ""
mkdir -p "$MDR/sub"; printf 'mine\n' > "$MDR/sub/nested-$MDID.txt"
_md_run
assert_eq "$(git -C "$MDR" show "master:sub/nested-$MDID.txt" 2>/dev/null || echo MISSING)" "MISSING" "nested untracked file in the merge's path: NOT merged"
assert_eq "$(cat "$MDR/sub/nested-$MDID.txt")" "mine" "nested untracked file in the merge's path: human's file untouched"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "nested untracked overlap: item PARKED in pending-merge"
# The PRECHECK must be what refuses, naming the offending path. Without -uall the overlap slips
# past the precheck, git refuses the merge itself, and deputy reports the misleading generic
# "the main tree changed since the check" instead — same outcome, useless diagnosis. This
# assertion is what distinguishes the two.
assert_contains "$(cat "$MDR/.runout")" "files this merge writes: sub/nested-$MDID.txt" "nested untracked overlap: precheck names the offending path (not the generic fallback)"

# I) NAMESPACE overlap: the human has an untracked FILE named 'sub', while the merge needs to
#    create the DIRECTORY 'sub/'. Neither path equals the other, so an exact-match intersection
#    misses it — the comparison has to treat ancestor/descendant pairs as overlapping.
_md_setup ""
printf 'not a directory\n' > "$MDR/sub"
_md_run
assert_eq "$(git -C "$MDR" show "master:sub/nested-$MDID.txt" 2>/dev/null || echo MISSING)" "MISSING" "file-vs-directory namespace overlap: NOT merged"
assert_eq "$(cat "$MDR/sub")" "not a directory" "file-vs-directory namespace overlap: human's file untouched"
assert_contains "$(DEPUTY_ROOT="$MDR" bash "$DEPUTY" list pending-merge)" "mdtest feature" "file-vs-directory namespace overlap: item PARKED in pending-merge"
assert_contains "$(cat "$MDR/.runout")" "files this merge writes: sub/nested-$MDID.txt" "file-vs-directory namespace overlap: precheck names the offending path"

# G) Control: a pristine tree still merges (the relaxation did not break the base case).
_md_setup ""
_md_run
assert_eq "$(_md_merged)" "feat $MDID" "clean tree: still auto-merges as before"
