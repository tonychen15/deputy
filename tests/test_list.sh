#!/usr/bin/env bash
# 'deputy list [--<state>]': bare lists all; --<state> filters to that state only
# (no leakage of other states); unknown flags/args exit 2.
# 'deputy list #<id>' / 'deputy list <N>' / 'deputy list --id <N>': filter by id.
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
assert_eq "$(printf '%s\n' "$w" | grep -cv '^[@?+!%=^;~]')" "2" "--waiting: both lines are waiting"
assert_eq "$(printf '%s\n' "$w" | grep -c '^[@?+!%=^;~]')"  "0" "--waiting: no non-waiting lines leak"
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

# ── ID filter ─────────────────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "alpha task" --p1 >/dev/null
bash "$DEPUTY" add "beta task"  --p2 >/dev/null
bash "$DEPUTY" add "gamma task" --p3 >/dev/null
# capture assigned IDs from the backlog
id_alpha="$(bash "$DEPUTY" list | grep 'alpha task' | grep -oE '#[0-9]+' | tr -d '#')"
id_beta="$(bash "$DEPUTY" list  | grep 'beta task'  | grep -oE '#[0-9]+' | tr -d '#')"

# '#<id>' form (quoted) shows exactly that item
r_hash="$(bash "$DEPUTY" list "#${id_alpha}")"
assert_eq "$(printf '%s\n' "$r_hash" | grep -c .)" "1" "list #<id> shows exactly 1 item"
assert_contains "$r_hash" "alpha task" "list #<id> content"
# must not leak other items
if printf '%s' "$r_hash" | grep -q "beta task"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: list #<id> leaked beta task\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi

# bare integer form
r_int="$(bash "$DEPUTY" list "$id_beta")"
assert_eq "$(printf '%s\n' "$r_int" | grep -c .)" "1" "list <N> shows exactly 1 item"
assert_contains "$r_int" "beta task" "list <N> content"

# --id flag form
r_flag="$(bash "$DEPUTY" list --id "$id_alpha")"
assert_contains "$r_flag" "alpha task" "list --id <N> content"

# --id=<N> flag form
r_flagq="$(bash "$DEPUTY" list "--id=${id_beta}")"
assert_contains "$r_flagq" "beta task" "list --id=<N> content"

# state + id combo: item IS in that state → shows it
bash "$DEPUTY" set "$(bash "$DEPUTY" list | grep 'gamma task' | head -1)" running >/dev/null
id_gamma="$(bash "$DEPUTY" list | grep 'gamma task' | grep -oE '#[0-9]+' | tr -d '#')"
r_combo="$(bash "$DEPUTY" list --running --id "$id_gamma")"
assert_eq "$(printf '%s\n' "$r_combo" | grep -c .)" "1" "list --running --id shows the item"
assert_contains "$r_combo" "gamma task" "list --running --id content"

# state + id combo: item NOT in that state → zero-match message
out_miss="$(bash "$DEPUTY" list --waiting --id "$id_gamma")"; rc_miss=$?
assert_eq "$rc_miss" "0" "list --waiting --id <running-item> exits 0"
assert_contains "$out_miss" "0 tasks with id #${id_gamma} in waiting state" "list --waiting --id zero-match message"

# id-only zero-match: non-existent id
out_noid="$(bash "$DEPUTY" list 99999)"; rc_noid=$?
assert_eq "$rc_noid" "0" "list <nonexistent-id> exits 0"
assert_contains "$out_noid" "0 tasks with id #99999" "list <nonexistent-id> zero-match message"

# error cases
bash "$DEPUTY" list '#abc'          >/dev/null 2>&1; assert_eq "$?" "2" "list #abc exits 2"
bash "$DEPUTY" list '#0'            >/dev/null 2>&1; assert_eq "$?" "2" "list #0 (non-positive) exits 2"
bash "$DEPUTY" list 0               >/dev/null 2>&1; assert_eq "$?" "2" "list 0 (non-positive) exits 2"
bash "$DEPUTY" list --id            >/dev/null 2>&1; assert_eq "$?" "2" "--id without value exits 2"
bash "$DEPUTY" list --id abc        >/dev/null 2>&1; assert_eq "$?" "2" "--id abc (non-numeric) exits 2"
bash "$DEPUTY" list --id=abc        >/dev/null 2>&1; assert_eq "$?" "2" "--id=abc exits 2"
bash "$DEPUTY" list "$id_alpha" "$id_beta" >/dev/null 2>&1; assert_eq "$?" "2" "duplicate id filter exits 2"
