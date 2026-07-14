#!/usr/bin/env bash
# tests/test_run_priority.sh — targeted-run priority-aware preemption tests (#102).
# Covers three cases:
#   (a) targeted run of higher-priority id while lower-priority item has a live claim →
#       running item paused (BACKLOG.md), warning printed; then on next invocation (after
#       worker exits) target runs normally (two-step cooperative preemption flow).
#   (b) targeted run of lower/equal-priority id while another item has a live claim →
#       target stays waiting, warning printed to stderr.
#   (c) non-targeted (cron/heartbeat) run while any item holds a live claim → silent skip.
source "$(dirname "$0")/lib.sh"

ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

# Helper: write an active-run.lock for a given live PID.
write_active_lock() {
  local root="$1" pid="$2"
  local start; start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true)"
  mkdir -p "$root/.deputy/active-run.lock"
  printf '%s\n' "$pid"   > "$root/.deputy/active-run.lock/pid"
  printf '%s\n' "$start" > "$root/.deputy/active-run.lock/start_time"
  printf 'run\n'         > "$root/.deputy/active-run.lock/owner"
  printf 'item\n'        > "$root/.deputy/active-run.lock/item"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$root/.deputy/active-run.lock/started_at"
}

# ── (a) Higher-priority targeted run: cooperative two-step preemption ─────────────────
# Step 1 — while #1(P3) is running: deputy run 2 should pause #1 and warn, not run #2.
# Step 2 — after the running worker exits: deputy run 2 should run #2 normally.
setup_repo
bash "$DEPUTY" add "low priority task" --p3 >/dev/null
bash "$DEPUTY" add "high priority task" --p2 >/dev/null
bash "$DEPUTY" list >/dev/null  # allocate IDs
item1a="$(bash "$DEPUTY" list | grep 'low priority task')"
sleep 300 & LIVE_A=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_A"
bash "$DEPUTY" claim "$item1a" --pid "$LIVE_A" >/dev/null 2>&1

# Step 1: targeted run while worker is alive → pause + warn, target stays waiting.
out_a1="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2 2>&1)"; rc_a1=$?
assert_eq "$rc_a1" "0" "(a1) higher-priority targeted run exits 0 while worker alive"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'low priority')")" "paused" \
  "(a1) lower-priority item is paused after targeted run"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'high priority')")" "waiting" \
  "(a1) higher-priority target stays waiting (cooperative — not yet runnable)"
assert_contains "$out_a1" "pausing"             "(a1) preemption message printed"
assert_contains "$out_a1" "next heartbeat"      "(a1) message explains when target will run"

# Step 2: kill fake worker (simulate worker exit), then run again → target runs.
kill "$LIVE_A" 2>/dev/null; wait "$LIVE_A" 2>/dev/null || true
out_a2="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2 2>&1)"; rc_a2=$?
assert_eq "$rc_a2" "0" "(a2) targeted run after worker exits exits 0"
assert_contains "$(bash "$DEPUTY" list)" "+[#"           "(a2) higher-priority target ran (done)"
assert_contains "$(bash "$DEPUTY" list)" "high priority" "(a2) target description preserved"

# ── (b) Lower-priority targeted run: target stays waiting, warning printed ────────────
# Setup: #1(P2) is running (live claim + live active-run lock), #2(P3) is waiting.
# Expected: #1 stays running, #2 stays waiting, warning to stderr.
setup_repo
bash "$DEPUTY" add "high priority running" --p2 >/dev/null
bash "$DEPUTY" add "low priority waiting" --p3 >/dev/null
bash "$DEPUTY" list >/dev/null
item1b="$(bash "$DEPUTY" list | grep 'high priority running')"
sleep 300 & LIVE_B=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_B"
bash "$DEPUTY" claim "$item1b" --pid "$LIVE_B" >/dev/null 2>&1

err_b="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2 2>&1 >/dev/null)"; rc_b=$?
assert_eq "$rc_b" "0" "(b) lower-priority targeted run exits 0"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'high priority running')")" "running" \
  "(b) higher-priority item stays running"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'low priority waiting')")" "waiting" \
  "(b) lower-priority target stays waiting"
assert_contains "$err_b" "left waiting"                    "(b) warning printed to stderr"
assert_contains "$err_b" "higher-priority task in progress" "(b) warning explains reason"
kill "$LIVE_B" 2>/dev/null || true

# ── (c) Non-targeted (cron) tick while an item holds a live claim → silent skip ───────
# Setup: #1(P3) is running (live claim). Call `deputy run --once` without a target id.
# Expected: rc=0, item stays running, no new claim or state change.
setup_repo
bash "$DEPUTY" add "cron task" --p3 >/dev/null
bash "$DEPUTY" list >/dev/null
item1c="$(bash "$DEPUTY" list | grep 'cron task')"
sleep 300 & LIVE_C=$!
bash "$DEPUTY" claim "$item1c" --pid "$LIVE_C" >/dev/null 2>&1

rc_c=0
DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --once 2>/dev/null || rc_c=$?
assert_eq "$rc_c" "0" "(c) cron tick with live claim exits 0"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'cron task')")" "running" \
  "(c) running item still running after cron tick (no state change)"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "(c) exactly one claim file still present (cron did not create a new one)"
kill "$LIVE_C" 2>/dev/null || true

rm -f "$ORCH"
