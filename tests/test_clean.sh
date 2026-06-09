#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# Seed a mix: two untouched (waiting) items, plus touched ones (done/cancelled/failed).
printf '%s\n' '[P0] active one' 'second waiting' '#[P1] finished thing' '%[P2] cancelled thing' '![P1] broken thing' >> "$DEPUTY_ROOT/BACKLOG.md"

# --- dry-run lists the untouched (waiting) items but changes nothing ---
out="$(bash "$DEPUTY" clean --dry-run)"
assert_contains "$out" "would remove 2" "dry-run counts untouched (waiting) items"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|" "dry-run leaves the file intact"
assert_contains "$(bash "$DEPUTY" list)" "active one"  "dry-run leaves active one"

# --- real clean removes untouched (waiting), keeps everything deputy has touched ---
bash "$DEPUTY" clean
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'active one\|second waiting')" "0" "clean removed the untouched items"
assert_contains "$out" "done|P1|"           "clean keeps done items"
assert_contains "$out" "finished thing"     "clean keeps done item description"
assert_contains "$out" "cancelled|P2|"      "clean keeps cancelled items"
assert_contains "$out" "cancelled thing"    "clean keeps cancelled item description"
assert_contains "$out" "failed|P1|"         "clean keeps failed items"
assert_contains "$out" "broken thing"       "clean keeps failed item description"

# --- legend/header survives ---
assert_eq "$(grep -c 'LEGEND' "$DEPUTY_ROOT/BACKLOG.md")" "1" "clean preserves the legend header"

# --- no consecutive blank lines left behind ---
assert_eq "$(awk 'BEGIN{p=0;d=0} /^[[:space:]]*$/{if(p)d++;p=1;next}{p=0} END{print d}' "$DEPUTY_ROOT/BACKLOG.md")" "0" "clean leaves no consecutive blank lines"

# --- no-op when there are no untouched items ---
out="$(bash "$DEPUTY" clean)"
assert_contains "$out" "nothing to clean" "clean is a no-op when no untouched items"

# ── New tests: --state <state> ────────────────────────────────────────────────

setup_repo
# Seed: waiting, done, failed, cancelled, duplicate items + a paused one
printf '%s\n' \
  '[P0] waiting alpha' \
  '#[P1] done beta' \
  '![P2] failed gamma' \
  '%[P0] cancelled delta' \
  '=[P1] duplicate epsilon' \
  '^[P2] paused zeta' \
  >> "$DEPUTY_ROOT/BACKLOG.md"

# --- --state done removes only done items ---
bash "$DEPUTY" clean --state done
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'done')" "0" "--state done removed the done item"
assert_contains "$out" "waiting"   "--state done leaves waiting items"
assert_contains "$out" "failed"    "--state done leaves failed items"
assert_contains "$out" "cancelled" "--state done leaves cancelled items"
assert_contains "$out" "duplicate" "--state done leaves duplicate items"
assert_contains "$out" "paused"    "--state done leaves paused items"
assert_contains "$out" "waiting alpha"    "--state done preserves waiting item description"

# --- --state failed removes only failed items ---
bash "$DEPUTY" clean --state failed
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'failed')" "0" "--state failed removed the failed item"
assert_contains "$out" "waiting"   "--state failed leaves waiting items"
assert_contains "$out" "cancelled" "--state failed leaves cancelled items"

# --- --state cancelled removes only cancelled items ---
bash "$DEPUTY" clean --state cancelled
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'cancelled')" "0" "--state cancelled removed the cancelled item"
assert_contains "$out" "waiting"   "--state cancelled leaves waiting items"
assert_contains "$out" "duplicate" "--state cancelled leaves duplicate items"

# --- --state duplicate removes only duplicate items ---
bash "$DEPUTY" clean --state duplicate
out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'duplicate')" "0" "--state duplicate removed the duplicate item"
assert_contains "$out" "waiting"   "--state duplicate leaves waiting items"
assert_contains "$out" "paused"    "--state duplicate leaves paused items"

# --- preserved [#N] ids, content, and header after --state cleans ---
setup_repo
printf '%s\n' \
  '[P0] keep one' \
  '#[P1] done two' \
  '[P2] keep three' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" clean --state done
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "keep one"   "IDs/content preserved: keep one present"
assert_contains "$out" "keep three" "IDs/content preserved: keep three present"
assert_eq "$(printf '%s\n' "$out" | grep -c 'done two')" "0" "done item removed"
# IDs should still be numeric (allocated)
assert_contains "$out" "|1|" "IDs still allocated after --state clean"
assert_eq "$(grep -c 'LEGEND' "$DEPUTY_ROOT/BACKLOG.md")" "1" "--state clean preserves legend/## Items header"

# --- no consecutive blank lines after --state clean ---
assert_eq "$(awk 'BEGIN{p=0;d=0} /^[[:space:]]*$/{if(p)d++;p=1;next}{p=0} END{print d}' "$DEPUTY_ROOT/BACKLOG.md")" "0" "--state clean leaves no consecutive blank lines"

# ── Refusal tests: active/checkpointed/awaiting states ───────────────────────

setup_repo
printf '%s\n' \
  '@[P0] running item' \
  '~[P1] triaging item' \
  '?[P0] surfaced item' \
  '^[P1] paused item' \
  '[P0] waiting item' \
  >> "$DEPUTY_ROOT/BACKLOG.md"

# --state running must be refused (non-zero + message + nothing removed)
rc=0; err="$(bash "$DEPUTY" clean --state running 2>&1)" || rc=$?
assert_eq "$rc" "1" "--state running returns non-zero"
assert_contains "$err" "refusing to clean running" "--state running shows refusal message"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "running item" "--state running does not remove the running item"

# --state triaging must be refused
rc=0; err="$(bash "$DEPUTY" clean --state triaging 2>&1)" || rc=$?
assert_eq "$rc" "1" "--state triaging returns non-zero"
assert_contains "$err" "refusing to clean triaging" "--state triaging shows refusal message"
assert_contains "$(bash "$DEPUTY" list)" "triaging item" "--state triaging does not remove the triaging item"

# --state surfaced must be refused
rc=0; err="$(bash "$DEPUTY" clean --state surfaced 2>&1)" || rc=$?
assert_eq "$rc" "1" "--state surfaced returns non-zero"
assert_contains "$err" "refusing to clean surfaced" "--state surfaced shows refusal message"

# --state paused must be refused
rc=0; err="$(bash "$DEPUTY" clean --state paused 2>&1)" || rc=$?
assert_eq "$rc" "1" "--state paused returns non-zero"
assert_contains "$err" "refusing to clean paused" "--state paused shows refusal message"

# --- invalid/unknown state → non-zero + message ---
rc=0; err="$(bash "$DEPUTY" clean --state foobar 2>&1)" || rc=$?
assert_eq "$rc" "2" "--state foobar returns exit 2"
assert_contains "$err" "unknown state" "--state foobar shows unknown-state message"

# ── Dry-run + --state ─────────────────────────────────────────────────────────

setup_repo
printf '%s\n' \
  '[P0] waiting alpha' \
  '#[P1] done beta' \
  '#[P2] done gamma' \
  '![P0] failed delta' \
  >> "$DEPUTY_ROOT/BACKLOG.md"

# --dry-run --state done lists but removes nothing
out="$(bash "$DEPUTY" clean --dry-run --state done)"
assert_contains "$out" "would remove 2" "--dry-run --state done counts done items"
assert_contains "$out" "done beta"      "--dry-run --state done lists done beta"
assert_contains "$out" "done gamma"     "--dry-run --state done lists done gamma"
# Nothing should be removed
assert_contains "$(bash "$DEPUTY" list)" "done beta"  "--dry-run --state done changes nothing (done beta still there)"
assert_contains "$(bash "$DEPUTY" list)" "done gamma" "--dry-run --state done changes nothing (done gamma still there)"

# --dry-run with --state=done (equals form) also works
out="$(bash "$DEPUTY" clean --dry-run --state=done)"
assert_contains "$out" "would remove 2" "--dry-run --state=done (equals form) counts items"

# Order tolerance: --state before --dry-run
out="$(bash "$DEPUTY" clean --state done --dry-run)"
assert_contains "$out" "would remove 2" "--state before --dry-run works"

# ── Back-compat: bare clean still removes waiting only ────────────────────────

setup_repo
printf '%s\n' \
  '[P0] w one' \
  '[P1] w two' \
  '#[P0] done three' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" clean)"
assert_contains "$out" "cleaned 2" "bare clean removes 2 waiting items (back-compat)"
list_out="$(bash "$DEPUTY" list)"
assert_eq "$(printf '%s\n' "$list_out" | grep -c 'w one\|w two')" "0" "bare clean removed waiting items"
assert_contains "$list_out" "done three" "bare clean preserved done items"
