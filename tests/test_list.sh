#!/usr/bin/env bash
# 'deputy list [--<state>]': bare lists all; --<state> filters to that state only
# (no leakage of other states); unknown flags/args exit 2.
source "$(dirname "$0")/lib.sh"

setup_repo
bash "$DEPUTY" add "wait one" --p0 >/dev/null
bash "$DEPUTY" add "wait two" --p1 >/dev/null
bash "$DEPUTY" add "to run"   --p2 >/dev/null
bash "$DEPUTY" add "to defer" --p3 >/dev/null
bash "$DEPUTY" list >/dev/null
lof() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }
bash "$DEPUTY" set "$(lof 'to run')"   running  >/dev/null
bash "$DEPUTY" set "$(lof 'to defer')" deferred >/dev/null

# bare list shows all four
all="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$all" | grep -c .)" "4" "bare list shows all items"

# --waiting shows exactly the two waiting items and nothing else
w="$(bash "$DEPUTY" list --waiting)"
assert_eq "$(printf '%s\n' "$w" | grep -c .)"            "2" "--waiting shows exactly 2 items"
assert_eq "$(printf '%s\n' "$w" | grep -c '^waiting|')"  "2" "--waiting: both lines are waiting"
assert_eq "$(printf '%s\n' "$w" | grep -vc '^waiting|')" "0" "--waiting: no non-waiting lines leak"
assert_contains "$w" "wait one" "--waiting includes wait one"
assert_contains "$w" "wait two" "--waiting includes wait two"

# --running / --deferred each match exactly one
r="$(bash "$DEPUTY" list --running)"
assert_eq "$(printf '%s\n' "$r" | grep -c .)" "1" "--running shows exactly 1"
assert_contains "$r" "to run" "--running content"
d="$(bash "$DEPUTY" list --deferred)"
assert_eq "$(printf '%s\n' "$d" | grep -c .)" "1" "--deferred shows exactly 1"
assert_contains "$d" "to defer" "--deferred content"

# a state with no items -> show '0 tasks in <state> state', clean exit
out="$(bash "$DEPUTY" list --paused)"; rc=$?
assert_eq "$rc" "0" "filter with no matches exits 0"
assert_contains "$out" "0 tasks in paused state" "filter with no matches prints zero-count message"

# bad input -> exit 2
bash "$DEPUTY" list --bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown state filter exits 2"
bash "$DEPUTY" list extra   >/dev/null 2>&1; assert_eq "$?" "2" "unexpected positional arg exits 2"

# unified grammar: a bare '<state>' positional filters (canonical), equivalent to
# '--state <state>' and the '--<state>' shorthand.
setup_repo
bash "$DEPUTY" add "bare-filter waiting item" --p2 >/dev/null
assert_contains "$(bash "$DEPUTY" list waiting)"         "bare-filter waiting item" "list <state> bare positional filters"
assert_contains "$(bash "$DEPUTY" list --state waiting)" "bare-filter waiting item" "list --state <state> filters"
np="$(bash "$DEPUTY" list done)"
if printf '%s' "$np" | grep -q "bare-filter waiting item"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: list done showed a waiting item\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi
