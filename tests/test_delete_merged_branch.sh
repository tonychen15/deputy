#!/usr/bin/env bash
# tests/test_delete_merged_branch.sh — #77: opt-in delete_merged_branch config key.
source "$(dirname "$0")/lib.sh"

# Helper: a real git repo so git branch operations work.
setup_git_repo() {
  setup_repo
  git -C "$DEPUTY_ROOT" init -q
  git -C "$DEPUTY_ROOT" config user.email t@t
  git -C "$DEPUTY_ROOT" config user.name t
  printf 'init\n' > "$DEPUTY_ROOT/file.txt"
  git -C "$DEPUTY_ROOT" add -A
  git -C "$DEPUTY_ROOT" commit -qm init
}

# Helper: create a deputy/<slug> branch and worktree, commit something on it.
create_branch_and_worktree() {
  local slug="$1" root="$2"
  local wt="$root/.deputy/wt"
  mkdir -p "$root/.deputy"
  git -C "$root" worktree add "$wt" -b "deputy/$slug" >/dev/null 2>&1
  printf 'work\n' >> "$wt/file.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -qm "step: work"
}

# Helper: merge the worktree branch into the current HEAD, simulating the clean-merge path.
do_merge() {
  local slug="$1" root="$2"
  git -C "$root" merge --no-ff "deputy/$slug" -qm "merge $slug"
}

# Run deputy wt-remove scoped to a given repo root.
# Must unset/override DEPUTY_WT so the inherited session value doesn't interfere.
run_wt_remove() {
  local root="$1"
  DEPUTY_ROOT="$root" DEPUTY_WT="$root/.deputy/wt" bash "$DEPUTY" wt-remove
}

# ── 1. config=1 + clean merge → branch is deleted after wt-remove ────────────
setup_git_repo
create_branch_and_worktree "feat-77a" "$DEPUTY_ROOT"
do_merge "feat-77a" "$DEPUTY_ROOT"
printf 'delete_merged_branch=1\n' > "$DEPUTY_ROOT/.deputy/config"
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-77a")"
assert_eq "$exists" "" "config=1 + clean merge: branch deleted after wt-remove"

# ── 2. config=0 (default) + clean merge → branch is preserved ────────────────
setup_git_repo
create_branch_and_worktree "feat-77b" "$DEPUTY_ROOT"
do_merge "feat-77b" "$DEPUTY_ROOT"
# Config key absent (default 0).
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-77b")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "config=0: branch preserved after wt-remove"

# ── 3. config=1 + NO merge (surface/abort path) → branch is preserved ────────
setup_git_repo
create_branch_and_worktree "feat-77c" "$DEPUTY_ROOT"
# Do NOT merge — simulates the surface/conflict-abort path.
printf 'delete_merged_branch=1\n' > "$DEPUTY_ROOT/.deputy/config"
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-77c")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "config=1 + no merge: branch preserved (not merged into HEAD)"

# ── 4. config=1 + cur_br is deputy/* (guard fires) → branch is preserved ─────
# If the main repo's HEAD is on a deputy/* branch when wt-remove is called,
# the cleanup guard fires and the branch is left intact.
setup_git_repo
create_branch_and_worktree "feat-77d" "$DEPUTY_ROOT"
do_merge "feat-77d" "$DEPUTY_ROOT"
# Remove the worktree first so feat-77d is no longer checked out in a linked worktree,
# then check it out in the main repo.
git -C "$DEPUTY_ROOT" worktree remove --force "$DEPUTY_ROOT/.deputy/wt" 2>/dev/null || true
git -C "$DEPUTY_ROOT" worktree prune 2>/dev/null || true
git -C "$DEPUTY_ROOT" checkout "deputy/feat-77d" 2>/dev/null
# Now create a fresh worktree for feat-77e to remove.
create_branch_and_worktree "feat-77e" "$DEPUTY_ROOT"
printf 'delete_merged_branch=1\n' > "$DEPUTY_ROOT/.deputy/config"
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-77e")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "config=1 + ROOT on deputy/* branch: guard fires, branch preserved"
git -C "$DEPUTY_ROOT" checkout master 2>/dev/null || true

# ── 5. #103: auto_merge=1, delete_merged_branch unset → branch deleted ───────
# Full automation implies cleanup: when auto_merge=1 and delete_merged_branch is
# not explicitly set, the branch is deleted after a clean merge.
setup_git_repo
create_branch_and_worktree "feat-103a" "$DEPUTY_ROOT"
do_merge "feat-103a" "$DEPUTY_ROOT"
printf 'auto_merge=1\n' > "$DEPUTY_ROOT/.deputy/config"   # delete_merged_branch NOT set
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-103a")"
assert_eq "$exists" "" "auto_merge=1 + delete_merged_branch unset: branch deleted (auto cleanup)"

# ── 6. #103: auto_merge=1, delete_merged_branch=0 → branch preserved ─────────
# Explicit opt-out wins even when auto_merge=1.
setup_git_repo
create_branch_and_worktree "feat-103b" "$DEPUTY_ROOT"
do_merge "feat-103b" "$DEPUTY_ROOT"
printf 'auto_merge=1\ndelete_merged_branch=0\n' > "$DEPUTY_ROOT/.deputy/config"
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-103b")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "auto_merge=1 + delete_merged_branch=0: explicit opt-out preserves branch"

# ── 7. #103: auto_merge=0, delete_merged_branch unset → branch preserved ─────
# No change for repos not using auto_merge: branch accumulation behaviour unchanged.
setup_git_repo
create_branch_and_worktree "feat-103c" "$DEPUTY_ROOT"
do_merge "feat-103c" "$DEPUTY_ROOT"
printf 'auto_merge=0\n' > "$DEPUTY_ROOT/.deputy/config"   # delete_merged_branch NOT set
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-103c")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "auto_merge=0 + delete_merged_branch unset: branch preserved (no change)"

# ── 8. #103: auto_merge=1, delete_merged_branch= (empty, explicit disable) → preserved ─
# An explicit empty value is a disable (#90 semantics: 'key=' overrides), distinct from unset;
# it must PRESERVE even under auto_merge=1 (present-but-not-1 wins over the auto_merge default).
setup_git_repo
create_branch_and_worktree "feat-103d" "$DEPUTY_ROOT"
do_merge "feat-103d" "$DEPUTY_ROOT"
printf 'auto_merge=1\ndelete_merged_branch=\n' > "$DEPUTY_ROOT/.deputy/config"
run_wt_remove "$DEPUTY_ROOT"
exists="$(git -C "$DEPUTY_ROOT" branch --list "deputy/feat-103d")"
[[ -n "$exists" ]] && result="exists" || result="gone"
assert_eq "$result" "exists" "auto_merge=1 + delete_merged_branch= (empty explicit disable): branch preserved"
