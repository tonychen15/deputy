#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '@ [P0] was running' '~ [P1] was triaging' '[P2] untouched' >> "$DEPUTY_ROOT/BACKLOG.md"

# A claim owned by a DEAD pid: pick an unused pid (99999) -> reverts + removed.
# Write the EXACT line that's in BACKLOG (before allocation changes it)
echo '@ [P0] was running' > "$DEPUTY_ROOT/.deputy/99999.claim"

bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "[P0]"           "stale claim reverted to waiting"
assert_contains "$out" "was running"    "stale claim: description preserved"
[[ -f "$DEPUTY_ROOT/.deputy/99999.claim" ]] && r=yes || r=no
assert_eq "$r" "no" "dead claim file removed"

# The triaging item had NO claim at all -> orphan revert.
assert_contains "$out" "[P1]"           "orphan triaging reverted"
assert_contains "$out" "was triaging"   "orphan triaging: description preserved"

# Untouched waiting item stays put.
assert_contains "$out" "[P2]"           "untouched item unchanged"
assert_contains "$out" "untouched"      "untouched item: description preserved"

# A claim owned by a LIVE pid must NOT be reverted.
setup_repo
printf '%s\n' '@ [P0] live work' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
echo '@ [P0] live work' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
bash "$DEPUTY" recover
assert_contains "$(bash "$DEPUTY" list)" "@[#"          "live claim preserved"
assert_contains "$(bash "$DEPUTY" list)" "live work"   "live claim: description preserved"
kill "$LIVE" 2>/dev/null

# Paused items must NOT be reverted — they represent checkpointed work.
setup_repo
printf '%s\n' '^[P0] paused midway' '^plain paused' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "^[#"           "recover leaves paused P0 intact"
assert_contains "$out" "paused midway" "recover leaves paused P0 description intact"
assert_contains "$out" "[P3]"          "recover leaves paused untagged (P3 default) intact"
assert_contains "$out" "plain paused"  "recover leaves paused untagged description intact"

# #62 interaction: a stale claim stored an OLD-order line (`@[P0][#1] x`) but BACKLOG has
# since migrated to the new canonical order (`@[#1][P0] x`). The exact-line revert no-ops,
# but the orphan-recovery backstop (revert any running item not held by a live claim, by
# its CURRENT line) must still recover it within the same `deputy recover`.
setup_repo
printf '%s\n' '@[#1][P0] migrated running' >> "$DEPUTY_ROOT/BACKLOG.md"
printf '%s\n%s\n%s\n' '@[P0][#1] migrated running' 'Mon Jan 1 00:00:00 2020' 'run' > "$DEPUTY_ROOT/.deputy/99998.claim"
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "[#1][P0] migrated running" "#62: old-order stale claim recovered via orphan backstop"
[[ -f "$DEPUTY_ROOT/.deputy/99998.claim" ]] && r=yes || r=no
assert_eq "$r" "no" "#62: old-order stale claim file removed"

# #62 + live claim: a LIVE claim stored an OLD-order line (`@[P0][#1] x`) while BACKLOG has
# migrated to new order (`@[#1][P0] x`). The orphan guard must match by CANONICAL identity,
# not raw text — otherwise the live-claimed running item is wrongly reverted to waiting.
setup_repo
printf '%s\n' '@[#1][P0] live migrated' >> "$DEPUTY_ROOT/BACKLOG.md"
# live agent claim (fresh heartbeat → live regardless of pid), line 1 = OLD order
printf '%s\n%s\n%s\n%s\n' '@[P0][#1] live migrated' 'start' 'agent' "$(date +%s)" > "$DEPUTY_ROOT/.deputy/99997.claim"
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "@[#1][P0] live migrated" "#62: live old-order claim NOT reverted (canonical match)"
[[ -f "$DEPUTY_ROOT/.deputy/99997.claim" ]] && r=yes || r=no
assert_eq "$r" "yes" "#62: live claim kept across order migration"
