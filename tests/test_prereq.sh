#!/usr/bin/env bash
# #114: prerequisite tasks — tests for [prereq:#N,#M] syntax, cmd_add --prereq,
# cmd_pick gate, cmd_analyze_dep, cmd_list annotation, and cmd_status blocked count.
source "$(dirname "$0")/lib.sh"

# ── block 1: basic add, list annotation, pick, status ────────────────────────
setup_repo
bash "$DEPUTY" add "task A" >/dev/null          # #1
bash "$DEPUTY" add "task B" >/dev/null          # #2
bash "$DEPUTY" add "task C" --prereq 1,2 >/dev/null  # #3 — blocked by #1,#2
bash "$DEPUTY" add "task D" --prereq 1   >/dev/null  # #4 — blocked by #1

# prereq tag round-trips in BACKLOG
backlog="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$backlog" "[prereq:#1,#2]" "task C has prereq tag with both IDs"
assert_contains "$backlog" "[prereq:#1]"    "task D has prereq tag with ID 1"

# list: blocked annotation appears for tasks with unmet prereqs
lst="$(bash "$DEPUTY" list)"
assert_contains "$lst" "[BLOCKED] waiting on:" "list annotates blocked items"
assert_contains "$lst" "#1(waiting)"            "blocked annotation names the prereq and state"

# list: no annotation for items without prereqs
assert_eq "$(printf '%s\n' "$lst" | grep 'task A' | grep -c BLOCKED)" "0" "task A has no BLOCKED annotation"
assert_eq "$(printf '%s\n' "$lst" | grep 'task B' | grep -c BLOCKED)" "0" "task B has no BLOCKED annotation"

# list: annotation disappears when prereq is satisfied
line1="$(grep 'task A' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$line1" done >/dev/null
lst2="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$lst2" | grep 'task D' | grep -c BLOCKED)" "0" "task D unblocked after prereq #1 done"
assert_contains "$lst2" "#2(waiting)" "task C still blocked by #2"
bash "$DEPUTY" set "$(grep 'task A' "$DEPUTY_ROOT/BACKLOG.md")" waiting >/dev/null

# pick: skips blocked items
pick="$(bash "$DEPUTY" pick)"
assert_eq "$(printf '%s' "$pick" | grep -c 'task C\|task D')" "0" "pick does not return blocked items"

# status: blocked count
status_out="$(bash "$DEPUTY" status)"
assert_contains "$status_out" "blocked:  2" "status shows 2 blocked items (C and D)"

# ── block 2: add --prereq validation ─────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "target" >/dev/null   # #1

bash "$DEPUTY" add "bad" --prereq "abc" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add --prereq rejects non-numeric IDs"

bash "$DEPUTY" add "ok" --prereq "#1" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "add --prereq accepts hash-prefixed IDs"

bash "$DEPUTY" add "bad" --prereq "1,2," 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add --prereq rejects trailing comma"

bash "$DEPUTY" add "dangles" --prereq 999 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add --prereq rejects dangling ID"

# ── block 3: analyze-dep — clean graph ───────────────────────────────────────
setup_repo
bash "$DEPUTY" add "prereq one" >/dev/null   # #1
bash "$DEPUTY" add "depends on 1" --prereq 1 >/dev/null  # #2

adep="$(bash "$DEPUTY" analyze-dep 2>&1)"; rc=$?
assert_eq "$rc" "0" "analyze-dep exits 0 when no structural defects"
assert_contains "$adep" "Blocked items" "analyze-dep reports blocked section"
assert_contains "$adep" "depends on 1"  "analyze-dep lists blocked item"

# ── block 4: analyze-dep — self-reference ────────────────────────────────────
setup_repo
printf '[#1][P3][prereq:#1] self-ref task\n' >> "$DEPUTY_ROOT/BACKLOG.md"
adep_self="$(bash "$DEPUTY" analyze-dep 2>&1)"; rc2=$?
assert_eq "$rc2" "1" "analyze-dep exits 1 on self-reference"
assert_contains "$adep_self" "Self-references" "analyze-dep reports self-reference"

# ── block 5: analyze-dep — dangling prereq ───────────────────────────────────
setup_repo
printf '[#1][P3][prereq:#99] dangling task\n' >> "$DEPUTY_ROOT/BACKLOG.md"
adep_dangle="$(bash "$DEPUTY" analyze-dep 2>&1)"; rc3=$?
assert_eq "$rc3" "1" "analyze-dep exits 1 on dangling prereq"
assert_contains "$adep_dangle" "Dangling" "analyze-dep reports dangling prereq"

# ── block 6: analyze-dep — cycle detection ───────────────────────────────────
setup_repo
printf '[#1][P3][prereq:#2] cycle A\n[#2][P3][prereq:#1] cycle B\n' >> "$DEPUTY_ROOT/BACKLOG.md"
adep_cycle="$(bash "$DEPUTY" analyze-dep 2>&1)"; rc4=$?
assert_eq "$rc4" "1" "analyze-dep exits 1 on cycle"
assert_contains "$adep_cycle" "unresolvable" "analyze-dep reports cycle"
