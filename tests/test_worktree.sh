#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# make the temp root a real git repo with one commit
git -C "$DEPUTY_ROOT" init -q
git -C "$DEPUTY_ROOT" config user.email t@t; git -C "$DEPUTY_ROOT" config user.name t
git -C "$DEPUTY_ROOT" add -A; git -C "$DEPUTY_ROOT" commit -qm init

bash "$DEPUTY" wt-create fix-thing
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt" ]] && echo yes || echo no)" "yes" "worktree created"
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "on item branch"

bash "$DEPUTY" wt-remove
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt" ]] && echo yes || echo no)" "no" "worktree removed"
assert_contains "$(git -C "$DEPUTY_ROOT" branch)" "deputy/fix-thing" "branch preserved after remove"

# resume: re-create attaching to existing branch
bash "$DEPUTY" wt-create fix-thing
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "resume attaches branch"
bash "$DEPUTY" wt-remove
