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
# #62 content-driven tags: priority by 'P', id by '#'; either order parses the same
assert_eq "$(parse '[#7][P1] new order')"      "waiting|P1|7|new order"   "parse new canonical order [#N][Pn]"
assert_eq "$(parse '[7] not an id')"           "waiting|||[7] not an id"  "bare [N] (no #) is NOT an id — stays in desc"

# ── Serialize: canonical order status[#N][Pn] description (#62: id first) ─────
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser waiting P1 7 'fix the bug')"  "[#7][P1] fix the bug"    "serialize waiting P1+id"
assert_eq "$(ser running P0 12 'run me')"      "@[#12][P0] run me"       "serialize running P0+id"
assert_eq "$(ser done '' 9 'done one')"        "+[#9] done one"          "serialize done+id"
assert_eq "$(ser waiting '' 3 'plain')"        "[#3] plain"              "serialize waiting no prio+id"
assert_eq "$(ser waiting P2 '' 'no id')"       "[P2] no id"              "serialize waiting P2 no id"
assert_eq "$(ser waiting '' '' 'bare')"        "bare"                    "serialize bare no prio no id"
assert_eq "$(ser paused P1 4 'paused')"        "^[#4][P1] paused"        "serialize paused P1+id"

# ── Parse/serialize round-trip ────────────────────────────────────────────────
# Parse then re-serialize must yield canonical form (#62: id-first [#N][Pn])
line="[#7][P0] do a thing"
parsed="$(parse "$line")"
state="${parsed%%|*}"; rest="${parsed#*|}"
prio="${rest%%|*}"; rest="${rest#*|}"
id="${rest%%|*}"; desc="${rest#*|}"
reser="$(ser "$state" "$prio" "$id" "$desc")"
assert_eq "$reser" "$line" "round-trip canonical form"

# Old (reversed) order normalizes to canonical on round-trip
line_rev="[P0][#7] do a thing"
parsed2="$(parse "$line_rev")"
state2="${parsed2%%|*}"; rest2="${parsed2#*|}"
prio2="${rest2%%|*}"; rest2="${rest2#*|}"
id2="${rest2%%|*}"; desc2="${rest2#*|}"
reser2="$(ser "$state2" "$prio2" "$id2" "$desc2")"
assert_eq "$reser2" "[#7][P0] do a thing" "old order normalizes to canonical [#N][Pn] on round-trip"

# ── _allocate_ids: sequential, idempotent, append-only ───────────────────────
setup_repo
bash "$DEPUTY" add "alpha" --p1
bash "$DEPUTY" add "beta"  --p0
bash "$DEPUTY" add "gamma"
# IDs are eagerly assigned in _do_add (insertion order); each add returns #N immediately:
# alpha(P1)=1, beta(P0)=2, gamma(P3)=3  (regroup doesn't affect ID assignment order)
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "[P1]"   "alloc: alpha has an id"
assert_contains "$out" "[P0]"   "alloc: beta has an id"
assert_contains "$out" "[P3]"   "alloc: gamma gets default P3"
assert_contains "$out" "alpha"  "alloc: alpha desc present"
assert_contains "$out" "beta"   "alloc: beta desc present"
assert_contains "$out" "[#1][P1] alpha" "alloc: alpha gets id 1 (first added)"
assert_contains "$out" "[#2][P0] beta"  "alloc: beta gets id 2 (second added)"
assert_contains "$out" "[#3][P3] gamma" "alloc: gamma gets id 3 with P3 default"

# Second pass is a no-op (ids don't change, new list call same result)
out2="$(bash "$DEPUTY" list)"
assert_contains "$out2" "[#1][P1] alpha"  "alloc idempotent: alpha still id 1"
assert_contains "$out2" "[#2][P0] beta"   "alloc idempotent: beta still id 2"

# New add gets max+1
bash "$DEPUTY" add "delta" --p2
out3="$(bash "$DEPUTY" list)"
# delta added; with eager id-assignment (#83) it already carries an id. Exact id depends
# on regroup order; just confirm it's present with its priority tag (BACKLOG format, #84).
assert_contains "$out3" "delta"   "alloc: delta added"
assert_contains "$out3" "[P2]"    "alloc: delta has id"

# ── deputy add output: 'deputy: added #<id>: <text>' ────────────────────────
setup_repo
out_add="$(DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "brand new item" --p2)"
assert_contains "$out_add" "added #" "add output includes 'added #'"
assert_contains "$out_add" "brand new item" "add output includes description"
# Extract the id from 'deputy: added #N: ...'
_test_id="${out_add#*#}"; _test_id="${_test_id%%:*}"
assert_eq "$([[ "$_test_id" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes" "add output has numeric id"
# Item is persisted immediately with the id (no list call needed to allocate)
assert_contains "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "[#${_test_id}]" "item persisted with id immediately on add"
assert_contains "$(DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" list)" "[#${_test_id}][P2] brand new item" "list confirms id and state"

# Done item's ID is not reused: add two, mark first done, add third
setup_repo
bash "$DEPUTY" add "task one"
bash "$DEPUTY" add "task two"
# IDs are eagerly assigned: task one = [#1], task two = [#2] (assigned on add, no list needed)
bash "$DEPUTY" list >/dev/null
raw_one="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_one" done
bash "$DEPUTY" add "task three"
out4="$(bash "$DEPUTY" list)"
assert_contains "$out4" "+[#1][P3] task one"  "done item keeps its id 1"
assert_contains "$out4" "[#2][P3] task two"   "task two keeps id 2"
assert_contains "$out4" "task three"          "task three present"
# task three must have id > 2 (max was 2, so 3)
assert_contains "$out4" "[#3][P3] task three" "new item gets id 3 (not reusing 1)"

# Status preserves id across state transitions
setup_repo
bash "$DEPUTY" add "check status" --p0
bash "$DEPUTY" list >/dev/null
raw="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw" done
out5="$(bash "$DEPUTY" list)"
assert_contains "$out5" "+[#1][P0] check status" "set done preserves id"

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
assert_contains "$out6" "+[#"   "regroup: P0 item preserved with id"
assert_contains "$out6" "[P2]"  "regroup: P2 item preserved with id"
assert_contains "$out6" "regroup urgent"   "regroup: urgent desc preserved"
assert_contains "$out6" "regroup waiting"  "regroup: waiting desc preserved"

# ── deputy run <id> ───────────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "low prio"  --p2
bash "$DEPUTY" add "high prio" --p0
# IDs eagerly assigned on add: low prio=1, high prio=2
bash "$DEPUTY" list >/dev/null  # no-op for IDs (already assigned); runs for safety
out_list="$(bash "$DEPUTY" list)"
# Verify the IDs so test is aware (insertion-order allocation)
assert_contains "$out_list" "[#1][P2] low prio"  "setup: low prio gets id 1 (added first)"
assert_contains "$out_list" "[#2][P0] high prio" "setup: high prio gets id 2 (added second)"

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
assert_contains "$(bash "$DEPUTY" list)" "+[#1][P2] low prio"  "run <id> marks targeted item done"
assert_contains "$(bash "$DEPUTY" list)" "[#2][P0] high prio"  "run <id> leaves high prio untouched"
rm -f "$ORCH_LOG"

# run <id> with leading # (deputy run '#1')
setup_repo
bash "$DEPUTY" add "hash id test" --p1
bash "$DEPUTY" list >/dev/null
assert_contains "$(bash "$DEPUTY" list)" "[#1][P1] hash id test" "setup: hash id test has id 1"
ORCH_LOG2="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG2" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run '#1' 2>&1 || true
assert_contains "$(bash "$DEPUTY" list)" "+[#1][P1] hash id test" "run '#1' accepted with leading hash"
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
assert_contains "$out11" "id must be a positive integer" "run non-integer → error message"

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

# ══ Sub-ids (#145.2): hand-written grouping labels, NO coupling to the parent ══
# A sub-id is a positive integer with a single '.<sub>' suffix. '#145' and '#145.2' are
# two INDEPENDENT tasks; the '.2' only tells a human they belong to the same effort.

# ── Parse / serialize round-trip ─────────────────────────────────────────────
assert_eq "$(parse '[#145.2] sub item')"        "waiting||145.2|sub item"      "parse bare sub-id"
assert_eq "$(parse '[P1][#145.2] sub item')"    "waiting|P1|145.2|sub item"    "parse P1 + sub-id"
assert_eq "$(parse '[#145.2][P1] sub item')"    "waiting|P1|145.2|sub item"    "parse sub-id + P1 reversed"
assert_eq "$(parse '@[#7.3][P0] running sub')"  "running|P0|7.3|running sub"   "parse running sub-id"
# a '.' inside the description body is NOT part of an id
assert_eq "$(parse '[#7] v1.2.3 release')"      "waiting||7|v1.2.3 release"    "desc dotted-version not eaten by id"
# a sub-id mentioned in the description body is not the item's id
assert_eq "$(parse '[#145.2] see [#145.9] too')" "waiting||145.2|see [#145.9] too" "desc sub-id ref stays in desc"
assert_eq "$(ser waiting P1 145.2 'sub item')"  "[#145.2][P1] sub item"        "serialize P1 + sub-id"
assert_eq "$(ser done '' 7.3 'done sub')"       "+[#7.3] done sub"             "serialize done sub-id"

# ── Allocation: hand-written sub-id is preserved, not clobbered ───────────────
# The integer PREFIX of a sub-id counts toward the next auto id (append-only, no recycling).
setup_repo
inject() { printf '%s\n' "$1" >> "$DEPUTY_ROOT/BACKLOG.md"; }
inject '[#145.2] big effort sub A'
out_alloc="$(bash "$DEPUTY" list)"
assert_contains "$out_alloc" "[#145.2]" "alloc: hand-written sub-id 145.2 preserved verbatim"
# the sub-id line must NOT have received a fresh integer id (no double id / mangling)
assert_eq "$(grep -c '\[#[0-9]*\]\[#145.2\]\|\[#145.2\]\[#[0-9]' "$DEPUTY_ROOT/BACKLOG.md")" "0" "alloc: sub-id not double-tagged with an integer id"
# a new add now gets 146 (max integer prefix 145 + 1), not 1 or 3
bash "$DEPUTY" add "after sub" --p3 >/dev/null
assert_contains "$(bash "$DEPUTY" list)" "[#146][P3] after sub" "alloc: next auto id = max-prefix+1 (146)"

# lone sub-id (no bare parent present) still contributes its prefix to the max scan
setup_repo
inject '[#200.1] lone sub'
bash "$DEPUTY" add "next one" >/dev/null
assert_contains "$(bash "$DEPUTY" list)" "[#201][P3] next one" "alloc: lone sub-id 200.1 → next id 201"

# a zero-padded prefix ('[#08]') must not trip bash octal arithmetic in the max scan (10#)
setup_repo
inject '[#08] padded legacy id'
out_oct="$(bash "$DEPUTY" add "after padded" 2>&1)"; rc_oct=$?
assert_eq "$rc_oct" "0" "alloc: zero-padded id [#08] does not crash the max scan"
assert_contains "$(bash "$DEPUTY" list)" "[#9][P3] after padded" "alloc: [#08] treated base-10 → next id 9"

# ── list filters by sub-id (bare, '#', and --id forms) ───────────────────────
setup_repo
inject '[#145.2] alpha sub'
inject '[#146] beta parent'
bash "$DEPUTY" list >/dev/null
assert_contains "$(bash "$DEPUTY" list 145.2)"       "alpha sub"  "list <sub-id> bare form matches"
assert_eq "$(bash "$DEPUTY" list 145.2 | grep -c 'beta parent')" "0" "list <sub-id> excludes other items"
assert_contains "$(bash "$DEPUTY" list '#145.2')"    "alpha sub"  "list '#<sub-id>' matches"
assert_contains "$(bash "$DEPUTY" list --id 145.2)"  "alpha sub"  "list --id <sub-id> matches"

# ── run <sub-id> targets exactly that item, bypassing priority ────────────────
setup_repo
inject '[#145.2] targeted sub'
inject '[#146][P0] urgent other'
bash "$DEPUTY" list >/dev/null
ORCH2="$(mktemp)"
cat > "$ORCH2" <<ORCHEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" > "\${ORCH_LOG:-/dev/null}"
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
ORCHEOF
chmod +x "$ORCH2"
ORCH_LOG4="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH2" ORCH_LOG="$ORCH_LOG4" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 145.2 2>&1 || true
assert_contains "$(cat "$ORCH_LOG4")" "targeted sub" "run <sub-id> ran the targeted sub-item"
assert_contains "$(bash "$DEPUTY" list)" "+[#145.2]" "run <sub-id> marked the sub-item done"
assert_contains "$(bash "$DEPUTY" list)" "[#146][P0] urgent other" "run <sub-id> left the higher-priority item untouched"
# leading-# form
DEPUTY_ORCHESTRATOR_CMD="$ORCH2" ORCH_LOG="$ORCH_LOG4" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run '#146' 2>&1 || true
assert_contains "$(bash "$DEPUTY" list)" "+[#146]" "run '#<id>' still works alongside sub-ids"
rm -f "$ORCH_LOG4"

# ── set <sub-id> resolves the item by its sub-id ─────────────────────────────
setup_repo
inject '[#145.2] set me'
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set 145.2 done
assert_contains "$(bash "$DEPUTY" list)" "+[#145.2][P3] set me" "set <sub-id> flips the sub-item's state"

# ── Validation: reject malformed sub-ids ─────────────────────────────────────
setup_repo
bash "$DEPUTY" add "any" >/dev/null
# Both parts must be positive+unpadded: reject a zero parent/sub ('0', '145.0', '0.1') too.
for bad in "145." ".2" "145..2" "145.2.3" "0.1" "1.2a" "145.0" "0" "00.1" "1.02"; do
  out_bad="$(bash "$DEPUTY" run "$bad" 2>&1)"; rc_bad=$?
  assert_eq "$rc_bad" "2" "run rejects malformed sub-id '$bad'"
done
# a valid sub-id that simply doesn't exist → 'no item', exit 1 (not a validation error)
out_missing="$(bash "$DEPUTY" run 999.9 2>&1)"; rc_missing=$?
assert_eq "$rc_missing" "1" "run <valid-but-absent sub-id> → exit 1"
assert_contains "$out_missing" "no item with id 999.9" "run absent sub-id → 'no item' message"

# set/clean must reject invalid id shapes CONSISTENTLY with run/list, even via the '#' form,
# so a hand-written malformed id (e.g. a stray '[#145.0]') is never silently mutated/deleted.
setup_repo
inject '[#145.0] malformed id line'   # parser is lenient, so this line exists with id 145.0
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set 145.0 done >/dev/null 2>&1 || true
assert_eq "$(bash "$DEPUTY" list | grep -c '+.*malformed id line')" "0" "set rejects invalid id 145.0 (line not flipped to done)"
out_clean="$(bash "$DEPUTY" clean '#145.0' 2>&1)"; rc_clean=$?
assert_eq "$rc_clean" "2" "clean '#145.0' → exit 2 (invalid id, not deleted)"
assert_contains "$out_clean" "invalid id" "clean '#<invalid>' → 'invalid id' message"
assert_contains "$(bash "$DEPUTY" list)" "malformed id line" "clean rejected the invalid id — line still present"

# ── Regex safety: the '.' in a sub-id must not act as a wildcard ──────────────
# cmd_slug greps the id against BACKLOG; an unescaped '1.2' would also match '[#152]'.
# The decoy is placed FIRST in file order so an unescaped pattern would return it (head -1).
setup_repo
inject '[#152] decoy line thing'
inject '[#1.2] genuine sub thing'
slug_out="$(bash "$DEPUTY" slug 1.2 2>&1)"
assert_contains "$slug_out" "genuine" "slug <sub-id> matches the exact line ('.' escaped, not a wildcard)"
assert_eq "$(printf '%s' "$slug_out" | grep -c 'decoy')" "0" "slug <sub-id> does not wildcard-match the decoy"
rm -f "$ORCH2"

# ── Exact id-field resolution: a description that MENTIONS "[#N]" never hijacks it ────
# An earlier item whose description references another item's id tag must not be the one a
# by-id lookup (set/run, and the merge/retry line lookups via _line_by_id) resolves.
setup_repo
inject '[#5] blocked on [#3] until reviewed'   # earlier line MENTIONS [#3] in its description
inject '[#3] the genuine target'
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set 3 done
after="$(bash "$DEPUTY" list)"
assert_contains "$after" "+[#3][P3] the genuine target"       "set <id> resolves the real [#3], not the line mentioning it"
assert_contains "$after" "[#5][P3] blocked on [#3] until reviewed" "set <id> left the mentioning [#5] item waiting"
