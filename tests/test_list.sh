#!/usr/bin/env bash
# 'deputy list [--<state>] [--porcelain]': bare lists all; --<state> filters to that
# state only (no leakage of other states); --porcelain emits stable pipe-delimited
# state|prio|id|desc per line; unknown flags/args exit 2.
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

# bare list shows all four (count via --porcelain: one line per item, no detail blocks)
all="$(bash "$DEPUTY" list)"
assert_eq "$(bash "$DEPUTY" list --porcelain | grep -c .)" "4" "bare list shows all items"

# --waiting shows exactly the two waiting items and nothing else
w="$(bash "$DEPUTY" list --waiting)"
assert_eq "$(bash "$DEPUTY" list --waiting --porcelain | grep -c .)" "2" "--waiting shows exactly 2 items"
assert_eq "$(printf '%s\n' "$w" | grep -v '^$' | grep -cv '^[@?+!%=^;~0-9]')" "2" "--waiting: both lines are waiting"
assert_eq "$(printf '%s\n' "$w" | grep -c '^[@?+!%=^;~]')"           "0" "--waiting: no non-waiting lines leak"
assert_contains "$w" "wait one" "--waiting includes wait one"
assert_contains "$w" "wait two" "--waiting includes wait two"
# blank lines: N-1 separators between N items + 1 blank before count summary = N total for N items
assert_eq "$(printf '%s\n' "$w" | grep -c '^$')"         "2" "--waiting: 2 blank lines (1 separator + 1 before count)"
assert_eq "$(printf '%s\n' "$w" | head -1 | grep -c .)"  "1" "--waiting: no leading blank line"
assert_eq "$(printf '%s\n' "$w" | tail -1 | grep -c .)"  "1" "--waiting: no trailing blank line"

# --running / --deferred each match exactly one
r="$(bash "$DEPUTY" list --running)"
assert_eq "$(bash "$DEPUTY" list --running --porcelain | grep -c .)" "1" "--running shows exactly 1"
assert_contains "$r" "to run" "--running content"
d="$(bash "$DEPUTY" list --deferred)"
# deferred is an attention state → its item now carries a detail block; count headers via --porcelain
assert_eq "$(bash "$DEPUTY" list --deferred --porcelain | grep -c .)" "1" "--deferred shows exactly 1"
assert_contains "$d" "to defer" "--deferred content"

# a state with no items -> show '0 tasks in <state> state', clean exit
out="$(bash "$DEPUTY" list --paused)"; rc=$?
assert_eq "$rc" "0" "filter with no matches exits 0"
assert_contains "$out" "0 tasks in paused state" "filter with no matches prints zero-count message"

# state filter with matching items -> count summary at bottom (#100)
w2="$(bash "$DEPUTY" list --waiting)"
assert_contains "$w2" "2 tasks in waiting state" "--waiting with items prints count summary"
r2="$(bash "$DEPUTY" list --running)"
assert_contains "$r2" "1 task in running state" "--running with 1 item prints singular count summary"
# bare list (no state filter) -> no count summary appended
all2="$(bash "$DEPUTY" list)"
if printf '%s' "$all2" | grep -qE '^[0-9]+ tasks in'; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: bare list should not print count summary\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi
# --porcelain suppresses count summary even with state filter
pr_wait="$(bash "$DEPUTY" list --waiting --porcelain)"
if printf '%s' "$pr_wait" | grep -qE '^[0-9]+ tasks in'; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: --porcelain should suppress count summary\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi

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

# state + id combo: item IS in that state → shows it + count summary (#100)
bash "$DEPUTY" set "$(bash "$DEPUTY" list | grep 'gamma task' | head -1)" running >/dev/null
id_gamma="$(bash "$DEPUTY" list | grep 'gamma task' | grep -oE '#[0-9]+' | tr -d '#')"
r_combo="$(bash "$DEPUTY" list --running --id "$id_gamma")"
assert_eq "$(printf '%s\n' "$r_combo" | grep -v '^$' | grep -c .)" "2" "list --running --id shows the item + count line"
assert_contains "$r_combo" "gamma task" "list --running --id content"
assert_contains "$r_combo" "1 task with id #${id_gamma} in running state" "list --running --id count summary singular"

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
