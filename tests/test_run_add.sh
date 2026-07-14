#!/usr/bin/env bash
# tests/test_run_add.sh — 'deputy run --<prio> <desc>' add+run mode (#104).
# Covers:
#   (a) New task is highest priority, nothing running → runs immediately
#   (b) New task is lower priority than existing waiting task → queued, message printed
#   (c) Equal-priority tie: existing task wins (FIFO), new task queued
#   (d) Running task is lower priority than new task → running task paused, message printed
#   (e) Running task is equal/higher priority → new task stays waiting, message printed
#   (f) Error: missing description after priority flag → exit 2
#   (g) Error: --p0 combined with explicit target id → exit 2
source "$(dirname "$0")/lib.sh"

ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

# Helper: write an active-run.lock for a given live PID (mirrors test_run_priority.sh).
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

# ── (a) New task is highest priority, nothing running → runs immediately ─────────────────
setup_repo
out_a="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p1 "add and run me" 2>&1)"; rc_a=$?
assert_eq "$rc_a" "0" "(a) run --p1 <desc> exits 0 (empty queue before add)"
assert_contains "$out_a" "added"                  "(a) add confirmation printed"
assert_contains "$out_a" "add and run me"         "(a) description in output"
assert_contains "$(bash "$DEPUTY" list)" "+[#"    "(a) task ran and is done"
assert_contains "$(bash "$DEPUTY" list)" "add and run me" "(a) description preserved in done state"

# ── (b) New task is lower priority than existing waiting task → queued only ───────────────
setup_repo
bash "$DEPUTY" add --p0 "urgent task" >/dev/null
out_b="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p3 "low prio task" 2>&1)"; rc_b=$?
assert_eq "$rc_b" "0" "(b) run --p3 exits 0 when higher-priority task waiting"
assert_contains "$out_b" "added"                  "(b) add confirmation printed"
assert_contains "$out_b" "queued"                 "(b) 'queued' message printed"
assert_contains "$out_b" "higher-priority"        "(b) reason shown in queue message"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'low prio task')")" "waiting" \
  "(b) new lower-priority task is waiting (not run)"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'urgent task')")" "waiting" \
  "(b) existing higher-priority task also still waiting (not auto-run)"

# ── (c) Equal-priority tie: FIFO wins, new task queued ───────────────────────────────────
setup_repo
bash "$DEPUTY" add --p1 "existing p1 task" >/dev/null
out_c="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p1 "new p1 task" 2>&1)"; rc_c=$?
assert_eq "$rc_c" "0" "(c) run --p1 exits 0 when equal-priority task already waiting"
assert_contains "$out_c" "queued"          "(c) 'queued' message printed for tied priority"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'new p1 task')")" "waiting" \
  "(c) new equal-priority task is waiting (FIFO: existing task takes precedence)"

# ── (d) Running task lower priority: new task causes cooperative preemption ───────────────
setup_repo
bash "$DEPUTY" add --p3 "background task" >/dev/null
bash "$DEPUTY" list >/dev/null   # allocate IDs
item_d="$(bash "$DEPUTY" list | grep 'background task')"
sleep 300 & LIVE_D=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_D"
bash "$DEPUTY" claim "$item_d" --pid "$LIVE_D" >/dev/null 2>&1

out_d="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p0 "urgent new task" 2>&1)"; rc_d=$?
assert_eq "$rc_d" "0" "(d) run --p0 exits 0 during preemption"
assert_contains "$out_d" "added"            "(d) add confirmation printed"
assert_contains "$out_d" "pausing"          "(d) preemption message printed"
assert_contains "$out_d" "next heartbeat"   "(d) message explains when new task will run"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'background task')")" "paused" \
  "(d) running lower-priority task is paused after preemption"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'urgent new task')")" "waiting" \
  "(d) new higher-priority task stays waiting (will run on next heartbeat)"
kill "$LIVE_D" 2>/dev/null; wait "$LIVE_D" 2>/dev/null || true

# ── (e) Running task equal/higher priority: new task stays waiting ────────────────────────
# Sub-case e1: running task is higher priority (P0 running, new is P2)
setup_repo
bash "$DEPUTY" add --p0 "top priority running" >/dev/null
bash "$DEPUTY" list >/dev/null
item_e="$(bash "$DEPUTY" list | grep 'top priority running')"
sleep 300 & LIVE_E=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_E"
bash "$DEPUTY" claim "$item_e" --pid "$LIVE_E" >/dev/null 2>&1

out_e="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p2 "normal new task" 2>&1)"; rc_e=$?
assert_eq "$rc_e" "0" "(e) run --p2 exits 0 when higher-priority task running"
assert_contains "$out_e" "added"              "(e) add confirmation printed"
assert_contains "$out_e" "left waiting"       "(e) 'left waiting' message printed"
assert_contains "$out_e" "in progress"        "(e) reason shown"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'top priority running')")" "running" \
  "(e) higher-priority running task stays running (no preemption)"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'normal new task')")" "waiting" \
  "(e) new lower-priority task stays waiting"
kill "$LIVE_E" 2>/dev/null; wait "$LIVE_E" 2>/dev/null || true

# Sub-case e2: running task is same priority (P2 running, new is P2 — tie = no preempt)
setup_repo
bash "$DEPUTY" add --p2 "equal priority running" >/dev/null
bash "$DEPUTY" list >/dev/null
item_e2="$(bash "$DEPUTY" list | grep 'equal priority running')"
sleep 300 & LIVE_E2=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_E2"
bash "$DEPUTY" claim "$item_e2" --pid "$LIVE_E2" >/dev/null 2>&1

out_e2="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run --p2 "new equal prio task" 2>&1)"; rc_e2=$?
assert_eq "$rc_e2" "0" "(e2) run --p2 exits 0 when equal-priority task running (tie = no preempt)"
assert_contains "$out_e2" "left waiting"    "(e2) equal-priority new task left waiting"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'equal priority running')")" "running" \
  "(e2) equal-priority running task stays running (tie = no preempt)"
assert_eq "$(line_state "$(bash "$DEPUTY" list | grep 'new equal prio task')")" "waiting" \
  "(e2) new equal-priority task stays waiting"
kill "$LIVE_E2" 2>/dev/null; wait "$LIVE_E2" 2>/dev/null || true

# ── (f) Error: missing description after priority flag → exit 2 ───────────────────────────
setup_repo
rc_f=0
bash "$DEPUTY" run --p1 2>/dev/null || rc_f=$?
assert_eq "$rc_f" "2" "(f) run --p1 with no description exits 2"

# ── (g) Error: --p0 combined with target id → exit 2 ─────────────────────────────────────
# The conflict triggers when a numeric target-id is parsed BEFORE the priority flag,
# because a positional integer is consumed as target_id while _add_prio is still unset.
# 'deputy run --p0 42' treats 42 as the description (no conflict); use 'run 42 --p0 desc'
# to put an integer in the target-id slot first.
setup_repo
rc_g=0
bash "$DEPUTY" run 42 --p0 "some desc" 2>/dev/null || rc_g=$?
assert_eq "$rc_g" "2" "(g) target-id combined with priority flag exits 2"

# ── Aliases: -ui (P0), -u (P1), -i (P2) ─────────────────────────────────────────────────
setup_repo
out_h="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run -u "alias task" 2>&1)"; rc_h=$?
assert_eq "$rc_h" "0" "(h) run -u <desc> (-u alias for --p1) exits 0"
assert_contains "$out_h" "added"             "(h) -u alias: add confirmation printed"
assert_contains "$(bash "$DEPUTY" list)" "+[#" "(h) -u alias: task ran and is done"

rm -f "$ORCH"
