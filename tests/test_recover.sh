#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '@ [P0] was running' '~ [P1] was triaging' '[P2] untouched' >> "$DEPUTY_ROOT/BACKLOG.md"

# A claim owned by a DEAD pid: pick an unused pid (99999) -> reverts + removed.
# Write the EXACT line that's in BACKLOG (before allocation changes it)
echo '@ [P0] was running' > "$DEPUTY_ROOT/.deputy/99999.claim"

bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|"    "stale claim reverted to waiting"
assert_contains "$out" "was running"    "stale claim: description preserved"
[[ -f "$DEPUTY_ROOT/.deputy/99999.claim" ]] && r=yes || r=no
assert_eq "$r" "no" "dead claim file removed"

# The triaging item had NO claim at all -> orphan revert.
assert_contains "$out" "waiting|P1|"    "orphan triaging reverted"
assert_contains "$out" "was triaging"   "orphan triaging: description preserved"

# Untouched waiting item stays put.
assert_contains "$out" "waiting|P2|"    "untouched item unchanged"
assert_contains "$out" "untouched"      "untouched item: description preserved"

# A claim owned by a LIVE pid must NOT be reverted.
setup_repo
printf '%s\n' '@ [P0] live work' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
echo '@ [P0] live work' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
bash "$DEPUTY" recover
assert_contains "$(bash "$DEPUTY" list)" "running|P0|" "live claim preserved"
assert_contains "$(bash "$DEPUTY" list)" "live work"   "live claim: description preserved"
kill "$LIVE" 2>/dev/null

# Paused items must NOT be reverted — they represent checkpointed work.
setup_repo
printf '%s\n' '^[P0] paused midway' '^plain paused' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "paused|P0|"    "recover leaves paused P0 intact"
assert_contains "$out" "paused midway" "recover leaves paused P0 description intact"
assert_contains "$out" "paused||"      "recover leaves paused untagged intact"
assert_contains "$out" "plain paused"  "recover leaves paused untagged description intact"
