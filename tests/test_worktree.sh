#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# make the temp root a real git repo with one commit
git -C "$DEPUTY_ROOT" init -q
git -C "$DEPUTY_ROOT" config user.email t@t; git -C "$DEPUTY_ROOT" config user.name t
git -C "$DEPUTY_ROOT" add -A; git -C "$DEPUTY_ROOT" commit -qm init

bash "$DEPUTY" wt-create fix-thing
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt-fix-thing" ]] && echo yes || echo no)" "yes" "worktree created"
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt-fix-thing" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "on item branch"

# wt-create prints the created path
out="$(bash "$DEPUTY" wt-create other-task)"
assert_eq "$out" "$DEPUTY_ROOT/.deputy/wt-other-task" "wt-create prints created path"
bash "$DEPUTY" wt-remove other-task

bash "$DEPUTY" wt-remove fix-thing
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt-fix-thing" ]] && echo yes || echo no)" "no" "worktree removed"
assert_contains "$(git -C "$DEPUTY_ROOT" branch)" "deputy/fix-thing" "branch preserved after remove"

# resume: re-create attaching to existing branch
bash "$DEPUTY" wt-create fix-thing
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt-fix-thing" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "resume attaches branch"
bash "$DEPUTY" wt-remove fix-thing

# wt-path returns the path without creating the worktree
assert_eq "$(bash "$DEPUTY" wt-path fix-thing)" "$DEPUTY_ROOT/.deputy/wt-fix-thing" "wt-path returns correct path"
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt-fix-thing" ]] && echo yes || echo no)" "no" "wt-path does not create worktree"

# slug converts text to canonical form
assert_eq "$(bash "$DEPUTY" slug "Fix the auth bug")" "fix-the-auth-bug" "slug: spaces to dashes"
assert_eq "$(bash "$DEPUTY" slug "Hello World! 123")" "hello-world-123" "slug: special chars removed"
assert_eq "$(bash "$DEPUTY" slug "  Leading spaces  ")" "leading-spaces" "slug: leading/trailing stripped"
