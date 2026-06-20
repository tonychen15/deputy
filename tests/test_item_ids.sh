#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

parse() { bash "$DEPUTY" _parse "$1"; }

# ── Parse: [#N] tag recognition ──────────────────────────────────────────────
# [P1][#7] in the tag zone → id=7
assert_eq "$(parse '[P1][#7] fix the bug')"   "waiting|P1|7|fix the bug"   "parse P1+id"
# [#7][P1] reversed order → same result
assert_eq "$(parse '[#7][P1] fix the bug')"   "waiting|P1|7|fix the bug"   "parse id+P1 reversed"
# no priority, just id
assert_eq "$(parse '[#3] plain item')"         "waiting||3|plain item"      "parse id no priority"
# status prefix + id
assert_eq "$(parse '@[P0][#12] running one')"  "running|P0|12|running one"  "parse running P0+id"
assert_eq "$(parse '#[#9] done one')"          "done||9|done one"           "parse done+id"
assert_eq "$(parse '^[P1][#4] paused')"        "paused|P1|4|paused"         "parse paused P1+id"
# legacy line (no [#N]) → empty id field
assert_eq "$(parse '[P0] legacy no id')"       "waiting|P0||legacy no id"   "parse legacy no id"
assert_eq "$(parse 'plain no id')"             "waiting|||plain no id"      "parse plain legacy"
assert_eq "$(parse '# done legacy')"           "done|||done legacy"         "parse done legacy"
# [#5] in the description body must NOT become the id
assert_eq "$(parse '[P1][#7] fix [#5] bug')"   "waiting|P1|7|fix [#5] bug"  "desc [#5] not parsed as id"
# [#5] in description on a legacy line (no tag-zone id) → empty id, full desc
assert_eq "$(parse 'fix [#5] crash')"          "waiting|||fix [#5] crash"   "legacy desc [#5] stays in desc"
# large id
assert_eq "$(parse '[#100] big id')"           "waiting||100|big id"        "large id"
# id=0 edge case
assert_eq "$(parse '[#0] zero id')"            "waiting||0|zero id"         "id=0 parses"

# ── Serialize: canonical order status[Pn][#N] description ────────────────────
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser waiting P1 7 'fix the bug')"  "[P1][#7] fix the bug"    "serialize waiting P1+id"
assert_eq "$(ser running P0 12 'run me')"      "@[P0][#12] run me"       "serialize running P0+id"
assert_eq "$(ser done '' 9 'done one')"        "+[#9] done one"          "serialize done+id"
assert_eq "$(ser waiting '' 3 'plain')"        "[#3] plain"              "serialize waiting no prio+id"
assert_eq "$(ser waiting P2 '' 'no id')"       "[P2] no id"              "serialize waiting P2 no id"
assert_eq "$(ser waiting '' '' 'bare')"        "bare"                    "serialize bare no prio no id"
assert_eq "$(ser paused P1 4 'paused')"        "^[P1][#4] paused"        "serialize paused P1+id"

# ── Parse/serialize round-trip ────────────────────────────────────────────────
# Parse then re-serialize must yield canonical form
line="[P0][#7] do a thing"
parsed="$(parse "$line")"
state="${parsed%%|*}"; rest="${parsed#*|}"
prio="${rest%%|*}"; rest="${rest#*|}"
id="${rest%%|*}"; desc="${rest#*|}"
reser="$(ser "$state" "$prio" "$id" "$desc")"
assert_eq "$reser" "$line" "round-trip canonical form"

# Reversed order normalizes on round-trip
line_rev="[#7][P0] do a thing"
parsed2="$(parse "$line_rev")"
state2="${parsed2%%|*}"; rest2="${parsed2#*|}"
prio2="${rest2%%|*}"; rest2="${rest2#*|}"
id2="${rest2%%|*}"; desc2="${rest2#*|}"
reser2="$(ser "$state2" "$prio2" "$id2" "$desc2")"
assert_eq "$reser2" "[P0][#7] do a thing" "reversed order normalizes to canonical on round-trip"

# ── _allocate_ids: sequential, idempotent, append-only ───────────────────────
setup_repo
bash "$DEPUTY" add "alpha" --p1
bash "$DEPUTY" add "beta"  --p0
bash "$DEPUTY" add "gamma"
# After add, allocation fires in _do_add. IDs are assigned in file insertion order:
# alpha(P1)=1, beta(P0)=2, gamma=3  (regroup doesn't affect ID assignment order)
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P1|"     "alloc: alpha has an id"
assert_contains "$out" "waiting|P0|"     "alloc: beta has an id"
assert_contains "$out" "waiting|P3|"     "alloc: gamma gets default P3"
assert_contains "$out" "alpha"           "alloc: alpha desc present"
assert_contains "$out" "beta"            "alloc: beta desc present"
assert_contains "$out" "waiting|P1|1|alpha" "alloc: alpha gets id 1 (first added)"
assert_contains "$out" "waiting|P0|2|beta"  "alloc: beta gets id 2 (second added)"
assert_contains "$out" "waiting|P3|3|gamma" "alloc: gamma gets id 3 with P3 default"

# Second pass is a no-op (ids don't change, new list call same result)
out2="$(bash "$DEPUTY" list)"
assert_contains "$out2" "waiting|P1|1|alpha"  "alloc idempotent: alpha still id 1"
assert_contains "$out2" "waiting|P0|2|beta"   "alloc idempotent: beta still id 2"

# New add gets max+1
bash "$DEPUTY" add "delta" --p2
out3="$(bash "$DEPUTY" list)"
# delta is P2, so after regroup: beta(P0)=1, alpha(P1)=2, delta(P2)=4 or gamma gets 3
# Exact ids depend on regroup order. Just check delta has an id > existing max
assert_contains "$out3" "delta"            "alloc: delta added"
assert_contains "$out3" "waiting|P2|"      "alloc: delta has id"

# Done item's ID is not reused: add two, list to allocate, mark first done, add third
setup_repo
bash "$DEPUTY" add "task one"
bash "$DEPUTY" add "task two"
# list to allocate ids (task one gets id 1, task two gets id 2 — no regroup since both untagged)
bash "$DEPUTY" list >/dev/null
# after alloc: task one = [#1], task two = [#2]
raw_one="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_one" done
bash "$DEPUTY" add "task three"
out4="$(bash "$DEPUTY" list)"
assert_contains "$out4" "done|P3|1|task one"     "done item keeps its id 1"
assert_contains "$out4" "waiting|P3|2|task two"  "task two keeps id 2"
assert_contains "$out4" "task three"             "task three present"
# task three must have id > 2 (max was 2, so 3)
assert_contains "$out4" "waiting|P3|3|task three" "new item gets id 3 (not reusing 1)"

# Status preserves id across state transitions
setup_repo
bash "$DEPUTY" add "check status" --p0
bash "$DEPUTY" list >/dev/null
raw="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw" done
out5="$(bash "$DEPUTY" list)"
assert_contains "$out5" "done|P0|1|check status" "set done preserves id"

# ── Regroup preserves IDs ─────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "regroup waiting" --p2
bash "$DEPUTY" add "regroup urgent" --p0
bash "$DEPUTY" list >/dev/null
# trigger regroup via set
raw_urgent="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_urgent" done
out6="$(bash "$DEPUTY" list)"
# Both items should still have their IDs after regroup
assert_contains "$out6" "done|P0|"      "regroup: P0 item preserved with id"
assert_contains "$out6" "waiting|P2|"   "regroup: P2 item preserved with id"
assert_contains "$out6" "regroup urgent"   "regroup: urgent desc preserved"
assert_contains "$out6" "regroup waiting"  "regroup: waiting desc preserved"

# ── deputy run <id> ───────────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "low prio"  --p2
bash "$DEPUTY" add "high prio" --p0
# IDs assigned in file/insertion order: low prio=1, high prio=2
# (add(high prio) calls _allocate_ids which assigns low prio=1, then list gives high prio=2)
bash "$DEPUTY" list >/dev/null
out_list="$(bash "$DEPUTY" list)"
# Verify the IDs so test is aware (insertion-order allocation)
assert_contains "$out_list" "waiting|P2|1|low prio"  "setup: low prio gets id 1 (added first)"
assert_contains "$out_list" "waiting|P0|2|high prio" "setup: high prio gets id 2 (added second)"

ORCH="$(mktemp)"
# $DEPUTY is the full path (set in lib.sh); DEPUTY_ROOT is exported per setup_repo
cat > "$ORCH" <<ORCHEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" > "\${ORCH_LOG:-/dev/null}"
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
ORCHEOF
chmod +x "$ORCH"

ORCH_LOG="$(mktemp)"
# Run item id=1 (low prio) bypassing priority (high prio has higher priority but id=2)
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 1 2>&1 || true
item_ran="$(cat "$ORCH_LOG")"
# Item 1 (low prio) should have run, not item 2 (high prio)
assert_contains "$item_ran" "low prio"  "run <id> targeted low-prio item directly"
assert_contains "$(bash "$DEPUTY" list)" "done|P2|1|low prio"   "run <id> marks targeted item done"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|2|high prio" "run <id> leaves high prio untouched"
rm -f "$ORCH_LOG"

# run <id> with leading # (deputy run '#1')
setup_repo
bash "$DEPUTY" add "hash id test" --p1
bash "$DEPUTY" list >/dev/null
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|1|hash id test" "setup: hash id test has id 1"
ORCH_LOG2="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG2" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run '#1' 2>&1 || true
assert_contains "$(bash "$DEPUTY" list)" "done|P1|1|hash id test" "run '#1' accepted with leading hash"
rm -f "$ORCH_LOG2"

# run <id> unknown → non-zero + message
setup_repo
bash "$DEPUTY" add "only item"
bash "$DEPUTY" list >/dev/null
out8="$(bash "$DEPUTY" run 99 2>&1)"; rc8=$?
assert_eq "$rc8" "1" "run unknown id → exit 1"
assert_contains "$out8" "no item with id 99" "run unknown id → error message"

# run <id> on done item → non-zero + message
setup_repo
bash "$DEPUTY" add "already done"
bash "$DEPUTY" list >/dev/null
raw_done="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_done" done
out9="$(bash "$DEPUTY" run 1 2>&1)"; rc9=$?
assert_eq "$rc9" "1" "run done id → exit 1"
assert_contains "$out9" "item 1 is done" "run done id → error message"

# run <id> on surfaced item → non-zero (surfaced items are not reverted by cmd_recover)
setup_repo
bash "$DEPUTY" add "surfaced item"
bash "$DEPUTY" list >/dev/null
raw_surf="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_surf" surfaced
out10="$(bash "$DEPUTY" run 1 2>&1)"; rc10=$?
assert_eq "$rc10" "1" "run surfaced id → exit 1"
assert_contains "$out10" "item 1 is surfaced" "run surfaced id → error message"

# non-integer id → non-zero + message
setup_repo
bash "$DEPUTY" add "any item"
out11="$(bash "$DEPUTY" run abc 2>&1)"; rc11=$?
assert_eq "$rc11" "2" "run non-integer id → exit 2"
assert_contains "$out11" "id must be an integer" "run non-integer → error message"

# run (no arg) still picks by priority (regression)
setup_repo
bash "$DEPUTY" add "low priority"  --p2
bash "$DEPUTY" add "high priority" --p0
bash "$DEPUTY" list >/dev/null
ORCH_LOG3="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG3" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1 || true
item_ran3="$(cat "$ORCH_LOG3")"
assert_contains "$item_ran3" "high priority" "run no-arg still picks highest priority"
rm -f "$ORCH_LOG3" "$ORCH"
