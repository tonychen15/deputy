#!/usr/bin/env bash
# test_heartbeat.sh — TDD for the always-on heartbeat (REVISION 2026-06-09)
# Covers:
#   1. --ensure reads heartbeat_mins from config (default 10, clamp bad values)
#   2. The cron line is NOT removed while running (always-on)
#   3. Tick skips when a live claim exists
#   4. Tick recovers + resumes an orphaned task
#   5. Tick leaves surfaced/failed alone
#   6. PID + start-time validation rejects a reused-PID stale claim
#   7. Retry budget marks item failed after 4 no-progress resumes
source "$(dirname "$0")/lib.sh"

# ── Fake crontab fixture ─────────────────────────────────────────────────────
STORE="$(mktemp)"; : > "$STORE"
FAKE="$(mktemp)"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-l" ]]; then cat "$STORE"; exit 0; fi
if [[ "\${1:-}" == "-" ]]; then cat > "$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE"
export DEPUTY_CRONTAB="$FAKE"

setup_repo

ROOT_HA="$DEPUTY_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# Test A1: --ensure with no heartbeat_mins config → writes */10
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/10 * * * *" \
  "ensure default: writes */10 (no heartbeat_mins)"
assert_eq "$(grep -c "deputy\[$ROOT_HA\]" "$STORE")" "1" \
  "ensure default: exactly one entry"

# ─────────────────────────────────────────────────────────────────────────────
# Test A2: --ensure with heartbeat_mins=5 → writes */5
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
printf 'heartbeat_mins=5\n' > "$ROOT_HA/.deputy/config"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/5 * * * *" \
  "ensure heartbeat_mins=5: writes */5"

# ─────────────────────────────────────────────────────────────────────────────
# Test A3: --ensure with heartbeat_mins=30 → writes */30
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
printf 'heartbeat_mins=30\n' > "$ROOT_HA/.deputy/config"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/30 * * * *" \
  "ensure heartbeat_mins=30: writes */30"

# ─────────────────────────────────────────────────────────────────────────────
# Test A4: heartbeat_mins=0 (invalid, < 1) → fall back to */10
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
printf 'heartbeat_mins=0\n' > "$ROOT_HA/.deputy/config"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/10 * * * *" \
  "ensure heartbeat_mins=0 invalid: falls back to */10"

# ─────────────────────────────────────────────────────────────────────────────
# Test A5: heartbeat_mins=60 (invalid, > 59) → fall back to */10
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
printf 'heartbeat_mins=60\n' > "$ROOT_HA/.deputy/config"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/10 * * * *" \
  "ensure heartbeat_mins=60 invalid: falls back to */10"

# ─────────────────────────────────────────────────────────────────────────────
# Test A6: heartbeat_mins=abc (non-integer) → fall back to */10
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
printf 'heartbeat_mins=abc\n' > "$ROOT_HA/.deputy/config"
bash "$DEPUTY" cron --ensure
assert_contains "$(cat "$STORE")" "*/10 * * * *" \
  "ensure heartbeat_mins=abc invalid: falls back to */10"

# ─────────────────────────────────────────────────────────────────────────────
# Test B: cron line is NOT removed during run (always-on model)
# ─────────────────────────────────────────────────────────────────────────────
: > "$STORE"
rm -f "$ROOT_HA/.deputy/config" 2>/dev/null || true
bash "$DEPUTY" cron --ensure    # installs */10, creates marker

bash "$DEPUTY" add "always-on item" --p0

# Capture crontab during orchestrator invocation
CAPTURE_B="$(mktemp)"
ORCH_B="$(mktemp)"
cat > "$ORCH_B" <<EOFB
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
[[ -s "$CAPTURE_B" ]] || cat "$STORE" > "$CAPTURE_B"
exit 0
EOFB
chmod +x "$ORCH_B"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_B" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

# The line must still be present DURING the run (always-on: NOT removed)
assert_eq "$(grep -c "deputy\[$ROOT_HA\]" "$CAPTURE_B" 2>/dev/null || true)" "1" \
  "always-on: cron line present DURING run (not removed)"
# And still present after idle exit
assert_eq "$(grep -c "deputy\[$ROOT_HA\]" "$STORE")" "1" \
  "always-on: cron line still present after idle exit"

rm -f "$ORCH_B" "$CAPTURE_B"

# ─────────────────────────────────────────────────────────────────────────────
# Test C: tick skips when a live claim exists (no double-claim)
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
ROOT_C="$DEPUTY_ROOT"
bash "$DEPUTY" add "concurrent item" --p0
bash "$DEPUTY" list >/dev/null   # allocate IDs

# Use a live background process and claim the item through deputy (writes correct claim format).
sleep 300 & LIVE_C=$!
item_line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" claim "$item_line" --pid "$LIVE_C" >/dev/null 2>&1

# Verify the item is now running and a live claim file exists.
assert_contains "$(bash "$DEPUTY" list)" "@[#" \
  "test setup: item is running before tick"

ORCH_C="$(mktemp)"
cat > "$ORCH_C" <<'EOFC'
#!/usr/bin/env bash
echo "SHOULD_NOT_RUN" >&2
exit 1
EOFC
chmod +x "$ORCH_C"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_C" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

# item must still be in running state (not claimed again, not reverted)
assert_contains "$(bash "$DEPUTY" list)" "@[#" \
  "tick skips: item stays running when live claim exists"

kill "$LIVE_C" 2>/dev/null || true
rm -f "$ORCH_C"

# ─────────────────────────────────────────────────────────────────────────────
# Test D: tick recovers an orphaned @running item (no live pid)
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
ROOT_D="$DEPUTY_ROOT"

# Add an item and manually put it in running state with a dead claim
bash "$DEPUTY" add "orphan task" --p0
bash "$DEPUTY" list >/dev/null  # allocate
orphan_line="$(bash "$DEPUTY" pick)"
# Put it to running in backlog
bash "$DEPUTY" set "$orphan_line" running >/dev/null 2>&1 || true
running_line="@[P0][#1] orphan task"
# Write a dead claim (pid 99998 should not exist)
printf '%s\n' "$running_line" > "$ROOT_D/.deputy/99998.claim"

ORCH_D="$(mktemp)"
cat > "$ORCH_D" <<EOFD
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
exit 0
EOFD
chmod +x "$ORCH_D"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_D" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

# The orphaned item should have been recovered and then run to done
list_out="$(bash "$DEPUTY" list)"
assert_contains "$list_out" "+[#" \
  "tick: orphaned task recovered and run to done"
assert_contains "$list_out" "orphan task" \
  "tick: orphaned task description preserved"

rm -f "$ORCH_D"

# ─────────────────────────────────────────────────────────────────────────────
# Test E: tick leaves surfaced and failed items alone
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
ROOT_E="$DEPUTY_ROOT"

printf '%s\n' '?[P0][#1] surfaced item' '![P1][#2] failed item' \
  >> "$ROOT_E/BACKLOG.md"

ORCH_E="$(mktemp)"
cat > "$ORCH_E" <<'EOFE'
#!/usr/bin/env bash
echo "SHOULD_NOT_RUN" >&2
exit 1
EOFE
chmod +x "$ORCH_E"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_E" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run >/dev/null 2>&1 || true

list_out="$(bash "$DEPUTY" list)"
assert_contains "$list_out" "?[#" \
  "tick: surfaced item left alone"
assert_contains "$list_out" "![#" \
  "tick: failed item left alone"

rm -f "$ORCH_E"

# ─────────────────────────────────────────────────────────────────────────────
# Test F: PID + start-time validation — reused PID with wrong start-time → dead
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
ROOT_F="$DEPUTY_ROOT"

bash "$DEPUTY" add "starttime test item" --p0
bash "$DEPUTY" list >/dev/null
f_item="$(bash "$DEPUTY" pick)"

# Use a real live pid but overwrite the claim file with the wrong start-time.
# First, use cmd_claim normally to put the item into running state.
sleep 300 & LIVE_F=$!
bash "$DEPUTY" claim "$f_item" --pid "$LIVE_F" >/dev/null 2>&1

# Now overwrite the claim file with a wrong start-time (simulates PID reuse after reboot).
running_f="$(sed -n '1p' "$ROOT_F/.deputy/$LIVE_F.claim" 2>/dev/null || true)"
WRONG_START="Mon Jan  1 00:00:00 1970"
printf '%s\n%s\n' "$running_f" "$WRONG_START" > "$ROOT_F/.deputy/$LIVE_F.claim"

ORCH_F="$(mktemp)"
cat > "$ORCH_F" <<EOFF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
exit 0
EOFF
chmod +x "$ORCH_F"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_F" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

# Wrong start-time → treated as dead → recovered → item runs to done
list_out="$(bash "$DEPUTY" list)"
assert_contains "$list_out" "+[#" \
  "start-time mismatch: stale claim treated as dead, item recovers and runs"

kill "$LIVE_F" 2>/dev/null || true
rm -f "$ORCH_F"

# ─────────────────────────────────────────────────────────────────────────────
# Test G: Retry budget — after 4 no-progress resumes, mark item failed
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
ROOT_G="$DEPUTY_ROOT"

bash "$DEPUTY" add "crashloop task" --p0
bash "$DEPUTY" list >/dev/null
g_item_raw="$(bash "$DEPUTY" pick)"
g_item_id="1"

# Start a waypoint for this item
bash "$DEPUTY" start "$g_item_id" "test crashloop" 2>/dev/null || true

# Orchestrator that always exits non-zero without committing any step
ORCH_G="$(mktemp)"
cat > "$ORCH_G" <<'EOFG'
#!/usr/bin/env bash
# Simulate a crash: don't mark done, just fail
exit 1
EOFG
chmod +x "$ORCH_G"

# First resume attempt: should run (attempt 1)
# We need to simulate the orchestrator dying mid-run by:
#   1. Placing the item in @running with a dead claim
#   2. Triggering a heartbeat tick (deputy run)
# And repeating 4 times to exhaust the budget

simulate_failed_run() {
  local step_num="$1"
  # Kill any live claims
  for f in "$ROOT_G/.deputy/"*.claim; do
    [[ -e "$f" ]] || continue
    rm -f "$f"
  done
  # Put item back to running with a dead claim
  # First recover to waiting if needed
  bash "$DEPUTY" recover >/dev/null 2>&1 || true
  local curr_line
  curr_line="$(bash "$DEPUTY" pick)"
  [[ -z "$curr_line" ]] && return 0
  # Write a dead claim
  printf '%s\n' "@[P0][#1] crashloop task" > "$ROOT_G/.deputy/88888.claim"
  # Put item to @running in BACKLOG
  bash "$DEPUTY" set "$curr_line" running >/dev/null 2>&1 || true
}

run_failed_attempt() {
  simulate_failed_run "$1"
  DEPUTY_ORCHESTRATOR_CMD="$ORCH_G" DEPUTY_AVAIL="claude,gemini" \
    DEPUTY_CRONTAB=/bin/true \
    bash "$DEPUTY" run --once >/dev/null 2>&1 || true
}

# Simulate 4 failed runs (no step committed each time)
run_failed_attempt 1
run_failed_attempt 2
run_failed_attempt 3

# Boundary: 3 attempts is still within budget — item must NOT be failed yet
case "$(bash "$DEPUTY" list)" in *'![#'*) boundary=failed ;; *) boundary=alive ;; esac
assert_eq "$boundary" "alive" \
  "retry budget: item still alive after 3 no-progress resumes (budget is 4)"

run_failed_attempt 4

# After 4 failed attempts with no step progress, item must be failed
list_out="$(bash "$DEPUTY" list)"
assert_contains "$list_out" "![#" \
  "retry budget: item marked failed after 4 no-progress resumes"
# Fail file should exist
assert_eq "$(ls "$ROOT_G/.deputy/fails/"*.md 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "retry budget: fails/<slug>.md written (#70)"

rm -f "$ORCH_G"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$STORE" "$FAKE"
