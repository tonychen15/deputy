#!/usr/bin/env bash
# Tests for the paused (^) state: parse/serialize, pick, claim, recover, status, set.
source "$(dirname "$0")/lib.sh"
setup_repo

# ── Parse / serialize ────────────────────────────────────────────────────────
printf '%s\n' '^[P0] paused urgent' '^plain paused' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "paused|P0|paused urgent" "paused P0 parsed"
assert_contains "$out" "paused||plain paused"    "paused untagged parsed"

ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3"; }
assert_eq "$(ser paused P1 'Interrupted job')" "^[P1] Interrupted job" "serialize paused P1"
assert_eq "$(ser paused '' 'Bare paused')"     "^Bare paused"          "serialize paused untagged"

# ── cmd_status counts paused ─────────────────────────────────────────────────
setup_repo
printf '%s\n' '^[P1] p1 paused' '^plain paused' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_contains "$(bash "$DEPUTY" status)" "paused:   2" "status paused count"

# ── cmd_pick picks paused items alongside waiting ─────────────────────────────
setup_repo
printf '%s\n' '^[P1] paused mid' '[P2] waiting low' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "^[P1] paused mid" "pick chooses paused P1 over waiting P2"

# paused and waiting at same priority: FIFO (file position) decides
setup_repo
printf '%s\n' '[P1] waiting first' '^[P1] paused second' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P1] waiting first" "pick FIFO: waiting before paused at same priority"

# paused with no waiting: paused is picked
setup_repo
printf '%s\n' '#[P0] done' '^[P2] paused job' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "^[P2] paused job" "pick returns paused when nothing waiting"

# ── cmd_claim accepts paused as source state ──────────────────────────────────
setup_repo
printf '^[P0] paused work\n' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "^[P0] paused work" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim from paused state succeeds"
assert_contains "$(bash "$DEPUTY" list)" "running|P0|paused work" "claimed paused item is running"
kill "$LIVE" 2>/dev/null

# ── cmd_recover leaves paused items alone ─────────────────────────────────────
setup_repo
printf '%s\n' '^[P0] checkpoint pause' '^[P1] another pause' '[P2] waiting' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "paused|P0|checkpoint pause" "recover preserves paused P0"
assert_contains "$out" "paused|P1|another pause"    "recover preserves paused P1"
assert_contains "$out" "waiting|P2|waiting"         "recover leaves waiting intact"

# ── cmd_set can transition to/from paused ─────────────────────────────────────
setup_repo
bash "$DEPUTY" add "future job" --p1
bash "$DEPUTY" set "[P1] future job" paused
assert_contains "$(bash "$DEPUTY" list)" "paused|P1|future job" "set waiting→paused"
bash "$DEPUTY" set "^[P1] future job" waiting
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|future job" "set paused→waiting"

# ── cmd_add: ^ prefix in description is rejected ─────────────────────────────
setup_repo
bash "$DEPUTY" add "^sneaky prefix" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects description starting with ^"
assert_eq "$(bash "$DEPUTY" list | grep -c 'sneaky')" "0" "rejected ^ description not written"
