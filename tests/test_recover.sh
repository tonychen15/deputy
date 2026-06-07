#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '@ [P0] was running' '~ [P1] was triaging' '[P2] untouched' >> "$DEPUTY_ROOT/BACKLOG.md"

# A claim owned by a DEAD pid: pick an unused pid (99999) -> reverts + removed.
echo '@ [P0] was running' > "$DEPUTY_ROOT/.deputy/99999.claim"

bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|was running"  "stale claim reverted to waiting"
[[ -f "$DEPUTY_ROOT/.deputy/99999.claim" ]] && r=yes || r=no
assert_eq "$r" "no" "dead claim file removed"

# The triaging item had NO claim at all -> orphan revert.
assert_contains "$out" "waiting|P1|was triaging" "orphan triaging reverted"

# Untouched waiting item stays put.
assert_contains "$out" "waiting|P2|untouched" "untouched item unchanged"

# A claim owned by a LIVE pid must NOT be reverted.
setup_repo
printf '%s\n' '@ [P0] live work' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
echo '@ [P0] live work' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
bash "$DEPUTY" recover
assert_contains "$(bash "$DEPUTY" list)" "running|P0|live work" "live claim preserved"
kill "$LIVE" 2>/dev/null
