#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# Seed a mix: two untouched (waiting) items, plus touched ones (done/cancelled/failed).
printf '%s\n' '[P0] active one' 'second waiting' '#[P1] finished thing' '%[P2] cancelled thing' '![P1] broken thing' >> "$DEPUTY_ROOT/BACKLOG.md"

# --- dry-run lists the untouched (waiting) items but changes nothing ---
out="$(bash "$DEPUTY" clean --dry-run)"
assert_contains "$out" "would remove 2" "dry-run counts untouched (waiting) items"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|active one" "dry-run leaves the file intact"

# --- real clean removes untouched (waiting), keeps everything deputy has touched ---
bash "$DEPUTY" clean
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'active one\|second waiting')" "0" "clean removed the untouched items"
assert_contains "$out" "done|P1|finished thing"      "clean keeps done items"
assert_contains "$out" "cancelled|P2|cancelled thing" "clean keeps cancelled items"
assert_contains "$out" "failed|P1|broken thing"      "clean keeps failed items"

# --- legend/header survives ---
assert_eq "$(grep -c 'LEGEND' "$DEPUTY_ROOT/BACKLOG.md")" "1" "clean preserves the legend header"

# --- no consecutive blank lines left behind ---
assert_eq "$(awk 'BEGIN{p=0;d=0} /^[[:space:]]*$/{if(p)d++;p=1;next}{p=0} END{print d}' "$DEPUTY_ROOT/BACKLOG.md")" "0" "clean leaves no consecutive blank lines"

# --- no-op when there are no untouched items ---
out="$(bash "$DEPUTY" clean)"
assert_contains "$out" "nothing to clean" "clean is a no-op when no untouched items"
