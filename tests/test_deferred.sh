#!/usr/bin/env bash
# Tests for the deferred (>) state: parse/serialize, set, pick, recover, regroup, clean.
source "$(dirname "$0")/lib.sh"

# ── Parse / serialize round-trip ────────────────────────────────────────────

setup_repo
# Raw deferred lines (no ID yet)
printf '%s\n' '>[P2][#3] x' '>plain deferred' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "deferred|P2|3|x"    "parse: deferred P2 #3 x"
assert_contains "$out" "deferred|"          "parse: deferred untagged has deferred state"
assert_contains "$out" "plain deferred"     "parse: deferred untagged description"

ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser deferred P2 3 'x')"             ">[P2][#3] x"           "serialize deferred P2 #3 x"
assert_eq "$(ser deferred '' '' 'plain deferred')" ">plain deferred"      "serialize deferred untagged"
assert_eq "$(ser deferred P1 '' 'Parked job')"    ">[P1] Parked job"      "serialize deferred P1 no-id"

# ── cmd_status counts deferred ───────────────────────────────────────────────
setup_repo
printf '%s\n' '>[P1] park one' '>park two' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_contains "$(bash "$DEPUTY" status)" "deferred: 2" "status deferred count"

# ── cmd_set: waiting → deferred, deferred → waiting ─────────────────────────
setup_repo
bash "$DEPUTY" add "future work" --p1
bash "$DEPUTY" list >/dev/null  # allocate IDs
future_line="$(bash "$DEPUTY" pick)"  # [P1][#1] future work
bash "$DEPUTY" set "$future_line" deferred
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "deferred|P1|"  "set waiting→deferred state"
assert_contains "$out" "future work"   "set waiting→deferred description preserved"

deferred_line="$(grep 'future work' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$deferred_line" waiting
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P1|"  "set deferred→waiting state"
assert_contains "$out" "future work"  "set deferred→waiting description preserved"

# ── cmd_pick skips deferred items ────────────────────────────────────────────
setup_repo
printf '%s\n' '>[P0] deferred urgent' '[P2] waiting low' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # allocate
pick_out="$(bash "$DEPUTY" pick)"
# Should pick the waiting item, NOT the deferred P0
assert_contains "$pick_out" "waiting low"      "pick skips deferred, picks waiting"
# Should not contain the deferred item
if [[ "$pick_out" == *"deferred urgent"* ]]; then
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: pick must not return deferred item\n' >&2
else
  TESTS_RUN=$((TESTS_RUN + 1))
fi

# When only deferred items exist, pick returns nothing
setup_repo
printf '%s\n' '>[P0] only deferred' '>[P1] another deferred' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pick_out2="$(bash "$DEPUTY" pick)"
assert_eq "$pick_out2" "" "pick returns empty when only deferred items exist"

# ── cmd_recover leaves deferred items untouched ──────────────────────────────
setup_repo
printf '%s\n' '>[P0] deferred checkpoint' '>[P1] another deferred' '[P2] waiting' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "deferred|P0|"          "recover preserves deferred P0"
assert_contains "$out" "deferred checkpoint"   "recover preserves deferred P0 description"
assert_contains "$out" "deferred|P1|"          "recover preserves deferred P1"
assert_contains "$out" "another deferred"      "recover preserves deferred P1 description"
assert_contains "$out" "waiting|P2|"           "recover leaves waiting intact"

# ── _regroup_backlog places deferred group in correct position ────────────────
# New sectioned order: Running → ... → Waiting → ... → Deferred → ... → Done
setup_repo
printf '%s\n' \
  '[P2] waiting one' \
  '@[P1] running one' \
  '>[P0] deferred one' \
  '#[P0] done one' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # allocate & regroup
running_line="$(grep '^@' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"
# Trigger a regroup by transitioning the running item back to running
bash "$DEPUTY" set "$running_line" running
body="$(awk '/^## Items/{found=1; next} found{print}' "$DEPUTY_ROOT/BACKLOG.md")"
wait_n="$(echo "$body"    | grep -n 'waiting one'  | cut -d: -f1)"
run_n="$(echo "$body"     | grep -n 'running one'  | cut -d: -f1)"
deferred_n="$(echo "$body" | grep -n 'deferred one' | cut -d: -f1)"
done_n="$(echo "$body"    | grep -n 'done one'     | cut -d: -f1)"
if [[ "$run_n" -lt "$wait_n" && "$wait_n" -lt "$deferred_n" && "$deferred_n" -lt "$done_n" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: sectioned order should be running < waiting < deferred < done\n  run=%s wait=%s deferred=%s done=%s\n' \
    "$run_n" "$wait_n" "$deferred_n" "$done_n" >&2
fi

# blank lines separate all groups
# There should be a blank line between active and deferred groups
blank_ad="$(echo "$body" | awk '/running one/{p=1} p && /^[[:space:]]*$/{b=1} b && /deferred one/{print "yes"; exit}')"
assert_eq "$blank_ad" "yes" "blank line between active and deferred groups"
blank_dt="$(echo "$body" | awk '/deferred one/{p=1} p && /^[[:space:]]*$/{b=1} b && /done one/{print "yes"; exit}')"
assert_eq "$blank_dt" "yes" "blank line between deferred and terminal groups"

# regroup preserves [#N] IDs and content
setup_repo
printf '%s\n' '[P1] waiting item' '>[P2][#3] parked forever' '#[P0] finished' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "deferred|P2|3|parked forever" "regroup preserves deferred [#N] id and content"
assert_contains "$out" "waiting|P1|"                   "regroup preserves waiting item"
assert_contains "$out" "done|P0|"                      "regroup preserves done item"

# ── cmd_clean --state deferred removes deferred items ────────────────────────
setup_repo
printf '%s\n' \
  '[P0] waiting alpha' \
  '>[P1] deferred beta' \
  '>[P2] deferred gamma' \
  '#[P0] done delta' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

# dry-run lists deferred items but removes nothing
out="$(bash "$DEPUTY" clean --dry-run --state deferred)"
assert_contains "$out" "would remove 2"     "--dry-run --state deferred counts deferred items"
assert_contains "$out" "deferred beta"      "--dry-run --state deferred lists deferred beta"
assert_contains "$out" "deferred gamma"     "--dry-run --state deferred lists deferred gamma"
# still present
assert_contains "$(bash "$DEPUTY" list)" "deferred beta"  "--dry-run leaves deferred beta intact"
assert_contains "$(bash "$DEPUTY" list)" "deferred gamma" "--dry-run leaves deferred gamma intact"

# real --state deferred removes them
bash "$DEPUTY" clean --state deferred
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'deferred beta\|deferred gamma')" "0" \
  "--state deferred removed both deferred items"
assert_contains "$out" "waiting alpha" "--state deferred leaves waiting items"
assert_contains "$out" "done delta"    "--state deferred leaves done items"

# ── bare `deputy clean` does NOT remove deferred items ───────────────────────
setup_repo
printf '%s\n' \
  '[P0] waiting to clean' \
  '>[P1] parked for later' \
  '#[P0] done thing' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" clean
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'waiting to clean')" "0" \
  "bare clean removes waiting items"
assert_contains "$out" "parked for later" "bare clean does NOT remove deferred items"
assert_contains "$out" "done thing"       "bare clean leaves done items"

# ── --state deferred is refused for active/awaiting states ───────────────────
# (deferred itself is cleanable; verify the refusal list still works correctly)
setup_repo
printf '%s\n' '@[P0] running item' '~[P1] triaging item' >> "$DEPUTY_ROOT/BACKLOG.md"
rc=0; err="$(bash "$DEPUTY" clean --state running 2>&1)" || rc=$?
assert_eq "$rc" "1" "--state running still returns non-zero"
assert_contains "$err" "refusing to clean running" "--state running refusal message intact"
