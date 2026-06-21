#!/usr/bin/env bash
# 'deputy release-notes' prints done items above the most-recent release delimiter
# as a CHANGELOG-ready bullet list. Read-only: BACKLOG.md is never modified.
source "$(dirname "$0")/lib.sh"
export DEPUTY_NOTIFY_SYNC=1

lof() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }

# --- no done items: prints 'No unreleased items.' ---
setup_repo
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 with no done items"
assert_eq "$out" "No unreleased items." "no done items prints message"

# --- no delimiter: all done items returned ---
setup_repo
bash "$DEPUTY" add "first task" --p1 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'first task')" done >/dev/null
bash "$DEPUTY" add "second task" --p2 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'second task')" done >/dev/null
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 with no delimiter"
assert_contains "$out" "first task" "all done items when no delimiter (first)"
assert_contains "$out" "second task" "all done items when no delimiter (second)"
assert_contains "$out" "- [#" "output uses bullet list format with id"

# --- items above delimiter returned; items below omitted ---
setup_repo
bash "$DEPUTY" add "shipped work" --p1 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'shipped work')" done >/dev/null
bash "$DEPUTY" release 1.0.0 >/dev/null 2>&1
bash "$DEPUTY" add "pending work" --p2 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'pending work')" done >/dev/null
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 with delimiter"
assert_contains "$out" "pending work" "item above delimiter is included"
assert_eq "$(printf '%s\n' "$out" | grep -c 'shipped work')" "0" "item below delimiter is excluded"

# --- nothing above delimiter: 'No unreleased items.' ---
setup_repo
bash "$DEPUTY" add "pre-release item" --p0 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'pre-release item')" done >/dev/null
bash "$DEPUTY" release 2.0.0 >/dev/null 2>&1
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 when nothing above delimiter"
assert_eq "$out" "No unreleased items." "nothing above delimiter prints message"

# --- BACKLOG.md removed: exit 1 + error message ---
setup_repo
rm -f "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "1" "exit 1 when BACKLOG.md missing"
assert_contains "$out" "not found" "error message when BACKLOG.md missing"

# --- multiple delimiters: only items above the first (most-recent) ---
setup_repo
bash "$DEPUTY" add "v1 item" --p1 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'v1 item')" done >/dev/null
bash "$DEPUTY" release 1.0.0 >/dev/null 2>&1
bash "$DEPUTY" add "v2 item" --p2 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'v2 item')" done >/dev/null
bash "$DEPUTY" release 2.0.0 >/dev/null 2>&1
bash "$DEPUTY" add "unreleased" --p3 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'unreleased')" done >/dev/null
out="$(bash "$DEPUTY" release-notes 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 with multiple delimiters"
assert_contains "$out" "unreleased" "item above most-recent delimiter is included"
assert_eq "$(printf '%s\n' "$out" | grep -c 'v2 item')" "0" "item between delimiters is excluded"
assert_eq "$(printf '%s\n' "$out" | grep -c 'v1 item')" "0" "item below oldest delimiter is excluded"

# --- READ-ONLY CONTRACT: BACKLOG.md unchanged after release-notes ---
setup_repo
bash "$DEPUTY" add "some task" --p1 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'some task')" done >/dev/null
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" release-notes >/dev/null 2>&1
after="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_eq "$before" "$after" "release-notes does not modify BACKLOG.md"
