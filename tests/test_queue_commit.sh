#!/usr/bin/env bash
# tests/test_queue_commit.sh — verify that deputy auto-commits BACKLOG.md after
# every mutation (add, set, claim, clean, recover), commits ONLY that file
# (unrelated dirty files are left alone), and handles non-git / untracked
# BACKLOG gracefully.
source "$(dirname "$0")/lib.sh"

# ── Helper: init a real git repo around the scratch BACKLOG ──────────────────
setup_git_repo() {
  setup_repo   # sets DEPUTY_ROOT + seeds BACKLOG.md
  git -C "$DEPUTY_ROOT" init -q
  git -C "$DEPUTY_ROOT" config user.email "test@deputy.test"
  git -C "$DEPUTY_ROOT" config user.name  "Deputy Test"
  # Commit the seeded BACKLOG.md so it is tracked.
  git -C "$DEPUTY_ROOT" add BACKLOG.md
  git -C "$DEPUTY_ROOT" commit -q -m "initial BACKLOG"
}

# ── 1. deputy add → BACKLOG.md auto-committed ────────────────────────────────
setup_git_repo
bash "$DEPUTY" add "queue commit test item"

# git status should show BACKLOG.md as clean (committed, not dirty).
# Exclude .deputy/ because it may be untracked (lock/state files), which is expected.
porcelain="$(git -C "$DEPUTY_ROOT" status --porcelain -- . ':!.deputy')"
assert_eq "$porcelain" "" "add: tree is clean after add (BACKLOG auto-committed)"

# Last commit message must start with 'chore(queue)'.
last_msg="$(git -C "$DEPUTY_ROOT" log -1 --format='%s')"
assert_contains "$last_msg" "chore(queue)" "add: last commit starts with chore(queue)"

# Only BACKLOG.md was changed in that commit.
files_in_commit="$(git -C "$DEPUTY_ROOT" diff-tree --no-commit-id -r --name-only HEAD)"
assert_eq "$files_in_commit" "BACKLOG.md" "add: commit touches only BACKLOG.md"

# ── 2. deputy set → BACKLOG.md auto-committed ────────────────────────────────
setup_git_repo
printf '%s\n' '[P0] item to set' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # allocate IDs
item_line="$(grep 'item to set' "$DEPUTY_ROOT/BACKLOG.md")"
# Stage the initial add (so the tree is clean before testing set).
git -C "$DEPUTY_ROOT" add BACKLOG.md && git -C "$DEPUTY_ROOT" commit -q -m "seed item"

bash "$DEPUTY" set "$item_line" running

porcelain="$(git -C "$DEPUTY_ROOT" status --porcelain -- . ':!.deputy')"
assert_eq "$porcelain" "" "set: tree is clean after set (BACKLOG auto-committed)"

last_msg="$(git -C "$DEPUTY_ROOT" log -1 --format='%s')"
assert_contains "$last_msg" "chore(queue)" "set: last commit starts with chore(queue)"

files_in_commit="$(git -C "$DEPUTY_ROOT" diff-tree --no-commit-id -r --name-only HEAD)"
assert_eq "$files_in_commit" "BACKLOG.md" "set: commit touches only BACKLOG.md"

# ── 3. deputy claim → BACKLOG.md auto-committed ──────────────────────────────
setup_git_repo
printf '%s\n' '[P1] item to claim' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
claim_line="$(bash "$DEPUTY" pick)"
git -C "$DEPUTY_ROOT" add BACKLOG.md && git -C "$DEPUTY_ROOT" commit -q -m "seed claim item"

sleep 300 & CLAIM_PID=$!
bash "$DEPUTY" claim "$claim_line" --pid "$CLAIM_PID"
kill "$CLAIM_PID" 2>/dev/null

porcelain="$(git -C "$DEPUTY_ROOT" status --porcelain -- . ':!.deputy')"
assert_eq "$porcelain" "" "claim: tree is clean after claim (BACKLOG auto-committed)"

last_msg="$(git -C "$DEPUTY_ROOT" log -1 --format='%s')"
assert_contains "$last_msg" "chore(queue)" "claim: last commit starts with chore(queue)"

files_in_commit="$(git -C "$DEPUTY_ROOT" diff-tree --no-commit-id -r --name-only HEAD)"
assert_eq "$files_in_commit" "BACKLOG.md" "claim: commit touches only BACKLOG.md"

# ── 4. deputy clean → BACKLOG.md auto-committed ──────────────────────────────
setup_git_repo
printf '%s\n' 'waiting one' 'waiting two' >> "$DEPUTY_ROOT/BACKLOG.md"
git -C "$DEPUTY_ROOT" add BACKLOG.md && git -C "$DEPUTY_ROOT" commit -q -m "seed waiting items"

bash "$DEPUTY" clean

porcelain="$(git -C "$DEPUTY_ROOT" status --porcelain -- . ':!.deputy')"
assert_eq "$porcelain" "" "clean: tree is clean after clean (BACKLOG auto-committed)"

last_msg="$(git -C "$DEPUTY_ROOT" log -1 --format='%s')"
assert_contains "$last_msg" "chore(queue)" "clean: last commit starts with chore(queue)"

files_in_commit="$(git -C "$DEPUTY_ROOT" diff-tree --no-commit-id -r --name-only HEAD)"
assert_eq "$files_in_commit" "BACKLOG.md" "clean: commit touches only BACKLOG.md"

# ── 5. deputy recover → BACKLOG.md auto-committed ────────────────────────────
setup_git_repo
printf '%s\n' '@ [P0] orphan running' >> "$DEPUTY_ROOT/BACKLOG.md"
git -C "$DEPUTY_ROOT" add BACKLOG.md && git -C "$DEPUTY_ROOT" commit -q -m "seed running item"

bash "$DEPUTY" recover

porcelain="$(git -C "$DEPUTY_ROOT" status --porcelain -- . ':!.deputy')"
assert_eq "$porcelain" "" "recover: tree is clean after recover (BACKLOG auto-committed)"

last_msg="$(git -C "$DEPUTY_ROOT" log -1 --format='%s')"
assert_contains "$last_msg" "chore(queue)" "recover: last commit starts with chore(queue)"

files_in_commit="$(git -C "$DEPUTY_ROOT" diff-tree --no-commit-id -r --name-only HEAD)"
assert_eq "$files_in_commit" "BACKLOG.md" "recover: commit touches only BACKLOG.md"

# ── 6. Unrelated dirty file stays dirty (commit is BACKLOG-only) ─────────────
setup_git_repo
# Create and track a sibling file.
printf 'initial\n' > "$DEPUTY_ROOT/notes.txt"
git -C "$DEPUTY_ROOT" add notes.txt && git -C "$DEPUTY_ROOT" commit -q -m "seed notes"
# Dirty it (unstaged change).
printf 'dirty\n' >> "$DEPUTY_ROOT/notes.txt"

bash "$DEPUTY" add "item with dirty sibling"

# notes.txt must still be dirty — deputy did NOT commit it.
dirty="$(git -C "$DEPUTY_ROOT" status --porcelain notes.txt)"
assert_contains "$dirty" "notes.txt" "dirty sibling file stays dirty after add"

# BACKLOG.md must be clean (committed).
backlog_status="$(git -C "$DEPUTY_ROOT" status --porcelain BACKLOG.md)"
assert_eq "$backlog_status" "" "BACKLOG.md is clean (committed) even with dirty sibling"

# ── 7. Non-git directory → graceful no-op ────────────────────────────────────
setup_repo   # no git init — plain temp dir
bash "$DEPUTY" add "non-git item"
# Should succeed without error (no git here, _commit_queue must not abort deputy).
rc=$?
assert_eq "$rc" "0" "add succeeds in non-git directory"
assert_contains "$(bash "$DEPUTY" list)" "non-git item" "item was written in non-git dir"

# ── 8. Untracked BACKLOG.md → graceful no-op ─────────────────────────────────
setup_repo
git -C "$DEPUTY_ROOT" init -q
git -C "$DEPUTY_ROOT" config user.email "test@deputy.test"
git -C "$DEPUTY_ROOT" config user.name  "Deputy Test"
# Do NOT add/commit BACKLOG.md — leave it untracked.

bash "$DEPUTY" add "untracked backlog item"
rc=$?
assert_eq "$rc" "0" "add succeeds when BACKLOG.md is untracked"
assert_contains "$(bash "$DEPUTY" list)" "untracked backlog item" "item written when BACKLOG untracked"

# BACKLOG.md must be in the untracked section (not staged, not committed).
ut="$(git -C "$DEPUTY_ROOT" status --porcelain BACKLOG.md)"
assert_contains "$ut" "??" "BACKLOG.md stays untracked (no git add by deputy)"

# ── 9. Surface: deputy help shows public set and NOT recover/probe/route/detect ─
out="$(bash "$DEPUTY" help 2>&1)"
assert_contains "$out" "add"     "help shows add"
assert_contains "$out" "list"    "help shows list"
assert_contains "$out" "status"  "help shows status"
assert_contains "$out" "run"     "help shows run"
assert_contains "$out" "cron"    "help shows cron"
assert_contains "$out" "review"  "help shows review"
assert_contains "$out" "set"     "help shows set"
assert_contains "$out" "clean"   "help shows clean"
assert_contains "$out" "reflect" "help shows reflect"

# These must NOT appear in the commands section of help.
# Capture only the commands block (between "commands:" and "config keys").
cmds_block="$(printf '%s\n' "$out" | awk '/^commands:/{found=1} found && /^config keys/{exit} found{print}')"
# 'recover' must not be a listed command
rc=0; printf '%s\n' "$cmds_block" | grep -qw 'recover' && rc=1
assert_eq "$rc" "0" "help does NOT list recover as a command"
rc=0; printf '%s\n' "$cmds_block" | grep -qw 'probe' && rc=1
assert_eq "$rc" "0" "help does NOT list probe as a command"
rc=0; printf '%s\n' "$cmds_block" | grep -qw 'route' && rc=1
assert_eq "$rc" "0" "help does NOT list route as a command"
rc=0; printf '%s\n' "$cmds_block" | grep -qw 'detect' && rc=1
assert_eq "$rc" "0" "help does NOT list detect as a command"

# ── 10. recover / probe / route / detect still callable ──────────────────────
setup_git_repo
# recover: should exit 0 (nothing to recover here).
bash "$DEPUTY" recover; rc=$?
assert_eq "$rc" "0" "recover still callable (exits 0)"
# probe: should exit 0 even if the CLI is absent (returns 'absent').
out_probe="$(bash "$DEPUTY" probe claude 2>&1)"; rc=$?
assert_eq "$rc" "0" "probe still callable (exits 0)"
# route: should return a valid answer (wait when no providers available).
out_route="$(bash "$DEPUTY" route orchestrate "" 2>&1)"
assert_contains "$out_route" "wait" "route still callable (returns wait when empty avail)"
# detect: should classify exit 0 as 'ok'.
out_detect="$(bash "$DEPUTY" detect claude 0 /dev/null 2>&1)"
assert_eq "$out_detect" "ok" "detect still callable (0→ok)"
