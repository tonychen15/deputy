#!/usr/bin/env bash
# 'deputy list [--<state>] [--porcelain]': bare lists all; --<state> filters to that
# state only (no leakage of other states); --porcelain emits stable pipe-delimited
# state|prio|id|desc per line; unknown flags/args exit 2.
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

# --porcelain: stable machine-readable pipe-delimited output
setup_repo
bash "$DEPUTY" add "porcelain item"      --p1 >/dev/null
bash "$DEPUTY" add "another item"        --p2 >/dev/null
bash "$DEPUTY" add "pipe|in|description" --p3 >/dev/null
bash "$DEPUTY" list >/dev/null  # allocate ids

# --porcelain emits one line per item; each line has exactly 3 pipe separators (4 fields)
por="$(bash "$DEPUTY" list --porcelain)"
assert_eq "$(printf '%s\n' "$por" | grep -c .)" "3" "--porcelain shows all 3 items"
while IFS= read -r line; do
  state="$(printf '%s' "$line" | cut -d'|' -f1)"
  prio="$( printf '%s' "$line" | cut -d'|' -f2)"
  id="$(   printf '%s' "$line" | cut -d'|' -f3)"
  desc="$(  printf '%s' "$line" | cut -d'|' -f4-)"
  assert_eq "$state" "waiting" "--porcelain: state field is 'waiting' for '$line'"
  [[ "$prio" =~ ^P[0-4]$ ]] || { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: --porcelain: prio field not P0-P4: %s\n' "$prio" >&2; }; TESTS_RUN=$((TESTS_RUN+1))
  [[ "$id"   =~ ^[0-9]+$ ]] || { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: --porcelain: id field not numeric: %s\n'   "$id"   >&2; }; TESTS_RUN=$((TESTS_RUN+1))
  [[ -n "$desc" ]]           || { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: --porcelain: desc field empty for: %s\n'    "$line" >&2; }; TESTS_RUN=$((TESTS_RUN+1))
done < <(printf '%s\n' "$por")

# desc field for 'pipe|in|description' is the raw remainder after the 3rd pipe
pipe_line="$(printf '%s\n' "$por" | grep '^waiting|P3|')"
assert_eq "$(printf '%s' "$pipe_line" | cut -d'|' -f4-)" "pipe|in|description" "--porcelain: desc with pipes is raw remainder after 3rd pipe"

# --porcelain composes with state filter
setup_repo
bash "$DEPUTY" add "running item" --p0 >/dev/null
lof2() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof2 'running item')" running >/dev/null
pr_run="$(bash "$DEPUTY" list --running --porcelain)"
assert_eq "$(printf '%s\n' "$pr_run" | grep -c .)" "1" "--porcelain --running shows exactly 1 item"
assert_eq "$(printf '%s' "$pr_run" | cut -d'|' -f1)" "running" "--porcelain --running: state field is 'running'"

# --porcelain with no matching items: exits 0 and emits no output (no human '0 tasks' message)
pr_none="$(bash "$DEPUTY" list --paused --porcelain)"; rc=$?
assert_eq "$rc" "0" "--porcelain with empty filter exits 0"
assert_eq "$(printf '%s' "$pr_none" | grep -c .)" "0" "--porcelain with empty filter emits no output (not the '0 tasks' message)"

# items without priority or id emit empty fields in porcelain output
setup_repo
bash "$DEPUTY" add "no-prio-no-id item" >/dev/null
bash "$DEPUTY" list >/dev/null
noprio_line="$(bash "$DEPUTY" list --porcelain | grep 'no-prio-no-id')"
assert_eq "$(printf '%s' "$noprio_line" | cut -d'|' -f1)" "waiting" "--porcelain: no-prio item state is waiting"
assert_eq "$(printf '%s' "$noprio_line" | cut -d'|' -f2)" "P3"      "--porcelain: default-priority item shows P3"
[[ "$(printf '%s' "$noprio_line" | cut -d'|' -f3)" =~ ^[0-9]+$ ]] \
  || { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: --porcelain: id not numeric for no-prio item\n' >&2; }; TESTS_RUN=$((TESTS_RUN+1))
