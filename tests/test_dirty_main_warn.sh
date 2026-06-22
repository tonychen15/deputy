#!/usr/bin/env bash
# #65: test that cmd_recover warns about stray main-tree changes after a dead claim.
source "$(dirname "$0")/lib.sh"

# Helper: set up a git-backed repo so git status works inside _check_main_tree_dirty.
setup_git_repo() {
  setup_repo
  git -C "$DEPUTY_ROOT" init -q
  git -C "$DEPUTY_ROOT" config user.email t@t
  git -C "$DEPUTY_ROOT" config user.name t
  # Seed a tracked file we can dirty later.
  printf 'original\n' > "$DEPUTY_ROOT/tracked.txt"
  git -C "$DEPUTY_ROOT" add -A
  git -C "$DEPUTY_ROOT" commit -qm init
}

# Helper: create a guaranteed-dead PID by spawning a no-op subprocess and waiting.
dead_pid() {
  true & local p=$!; wait "$p" 2>/dev/null || true; printf '%s' "$p"
}

# ── 1. Dead claim + tracked modification → warning on stderr ─────────────────
setup_git_repo
DEAD="$(dead_pid)"
printf '%s\n' '@ [P0] was running' >> "$DEPUTY_ROOT/BACKLOG.md"
echo '@ [P0] was running' > "$DEPUTY_ROOT/.deputy/$DEAD.claim"
# Dirty the main tree with a tracked modification.
printf 'modified\n' >> "$DEPUTY_ROOT/tracked.txt"
warn="$(bash "$DEPUTY" recover 2>&1 >/dev/null)"
assert_contains "$warn" "WARNING" "dead claim + tracked mod: warning emitted"
assert_contains "$warn" "$DEAD"   "dead claim + tracked mod: pid correlated in warning"
assert_contains "$warn" "tracked.txt" "dead claim + tracked mod: dirty file listed"

# ── 2. Dead claim + untracked file → warning on stderr ───────────────────────
setup_git_repo
DEAD="$(dead_pid)"
printf '%s\n' '@ [P0] stray work' >> "$DEPUTY_ROOT/BACKLOG.md"
echo '@ [P0] stray work' > "$DEPUTY_ROOT/.deputy/$DEAD.claim"
# Dirty the main tree with an untracked file.
printf 'new file\n' > "$DEPUTY_ROOT/untracked.txt"
warn="$(bash "$DEPUTY" recover 2>&1 >/dev/null)"
assert_contains "$warn" "WARNING"      "dead claim + untracked file: warning emitted"
assert_contains "$warn" "untracked.txt" "dead claim + untracked file: dirty file listed"

# ── 3. Live claim + dirty tree → NO warning ──────────────────────────────────
setup_git_repo
printf '%s\n' '@ [P0] live work' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
echo '@ [P0] live work' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
printf 'modified\n' >> "$DEPUTY_ROOT/tracked.txt"
warn="$(bash "$DEPUTY" recover 2>&1 >/dev/null)"
no_warn="${warn:-clean}"
[[ "$warn" != *"WARNING"* ]] && no_warn="clean" || no_warn="warned"
assert_eq "$no_warn" "clean" "live claim + dirty tree: no warning (worker still running)"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null || true

# ── 4. No dead claim + dirty tree → NO warning ───────────────────────────────
setup_git_repo
# Dirty the tree with no claim files at all.
printf 'modified\n' >> "$DEPUTY_ROOT/tracked.txt"
warn="$(bash "$DEPUTY" recover 2>&1 >/dev/null)"
[[ "$warn" != *"WARNING"* ]] && no_warn="clean" || no_warn="warned"
assert_eq "$no_warn" "clean" "no dead claim + dirty tree: no warning (could be human WIP)"

# ── 5. deputy doctor reports dirty files ─────────────────────────────────────
setup_git_repo
printf 'modified\n' >> "$DEPUTY_ROOT/tracked.txt"
printf 'new file\n' > "$DEPUTY_ROOT/untracked.txt"
out="$(bash "$DEPUTY" doctor 2>&1)"
assert_contains "$out" "WARNING"       "doctor: reports WARNING when dirty"
assert_contains "$out" "tracked.txt"   "doctor: lists tracked modification"
assert_contains "$out" "untracked.txt" "doctor: lists untracked file"

# ── 6. deputy doctor reports clean when tree is clean ────────────────────────
setup_git_repo
out="$(bash "$DEPUTY" doctor 2>&1)"
assert_contains "$out" "clean" "doctor: reports clean when no stray changes"
