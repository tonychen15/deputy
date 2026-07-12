#!/usr/bin/env bash
# tests/test_active_run_lock.sh — long-lived active-run ownership lock tests.
source "$(dirname "$0")/lib.sh"

proc_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//' || true
}

write_active_lock() {
  local root="$1" pid="$2" start="$3" item="${4:-test item}"
  mkdir -p "$root/.deputy/active-run.lock"
  printf '%s\n' "$pid" > "$root/.deputy/active-run.lock/pid"
  printf '%s\n' "$start" > "$root/.deputy/active-run.lock/start_time"
  printf 'test\n' > "$root/.deputy/active-run.lock/owner"
  printf '%s\n' "$item" > "$root/.deputy/active-run.lock/item"
  printf '2026-06-20T00:00:00Z\n' > "$root/.deputy/active-run.lock/started_at"
}

make_done_orchestrator() {
  local f
  f="$(mktemp)"
  printf '#!/usr/bin/env bash\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# Live active-run lock blocks a new run without claiming the waiting item.
setup_repo
printf '[P1] blocked by active lock\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
sleep 300 & LIVE_LOCK_PID=$!
write_active_lock "$DEPUTY_ROOT" "$LIVE_LOCK_PID" "$(proc_start "$LIVE_LOCK_PID")"
ORCH="$(make_done_orchestrator)"

DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude,gemini" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2>/tmp/active_lock_live.err
state="$(line_state "$(bash "$DEPUTY" list | head -1)")"
assert_eq "$state" "waiting" "live active-run lock blocks a new run"
assert_contains "$(cat /tmp/active_lock_live.err)" "active run exists" \
  "live active-run lock emits skip reason"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "live active-run lock does not create a claim"

kill "$LIVE_LOCK_PID" 2>/dev/null || true
rm -f "$ORCH"

# Stale active-run lock is removed and the item can run.
setup_repo
printf '[P1] stale lock can run\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
sleep 1 & DEAD_LOCK_PID=$!
DEAD_START="$(proc_start "$DEAD_LOCK_PID")"
kill "$DEAD_LOCK_PID" 2>/dev/null; wait "$DEAD_LOCK_PID" 2>/dev/null || true
write_active_lock "$DEPUTY_ROOT" "$DEAD_LOCK_PID" "$DEAD_START"
ORCH="$(make_done_orchestrator)"

DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude,gemini" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2>/tmp/active_lock_stale.err
state="$(line_state "$(bash "$DEPUTY" list | head -1)")"
assert_eq "$state" "done" "stale active-run lock is cleared and run proceeds"
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/active-run.lock" ]] && echo yes || echo no)" "no" \
  "active-run lock is released after successful run"

rm -f "$ORCH"

# PID reuse/start-time mismatch is treated as stale and reclaimed.
setup_repo
printf '[P1] mismatched lock can run\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
sleep 300 & REUSED_PID=$!
write_active_lock "$DEPUTY_ROOT" "$REUSED_PID" "not the real start time"
ORCH="$(make_done_orchestrator)"

DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_AVAIL="claude,gemini" DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  bash "$DEPUTY" run 2>/tmp/active_lock_reused.err
state="$(line_state "$(bash "$DEPUTY" list | head -1)")"
assert_eq "$state" "done" "PID start-time mismatch lock is reclaimed and run proceeds"

kill "$REUSED_PID" 2>/dev/null || true
rm -f "$ORCH"

# Guardrail ignores stale/dead active-run locks for non-owner sessions.
setup_repo
sleep 1 & DEAD_GUARD_PID=$!
DEAD_GUARD_START="$(proc_start "$DEAD_GUARD_PID")"
kill "$DEAD_GUARD_PID" 2>/dev/null; wait "$DEAD_GUARD_PID" 2>/dev/null || true
write_active_lock "$DEPUTY_ROOT" "$DEAD_GUARD_PID" "$DEAD_GUARD_START"
guard_rc="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' \
  | DEPUTY_ROOT="$DEPUTY_ROOT" bash "$REPO/hooks/guardrail.sh" >/dev/null 2>&1; echo $?)"
assert_eq "$guard_rc" "0" "guardrail ignores dead active-run lock"

# Release refuses to remove a lock owned by another live process.
setup_repo
sleep 300 & OTHER_PID=$!
write_active_lock "$DEPUTY_ROOT" "$OTHER_PID" "$(proc_start "$OTHER_PID")"
DEPUTY_ROOT="$DEPUTY_ROOT" bash -c 'source "'"$DEPUTY"'"; _active_run_release' >/dev/null 2>&1
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/active-run.lock" ]] && echo yes || echo no)" "yes" \
  "active-run release refuses another owner"
kill "$OTHER_PID" 2>/dev/null || true

# ── #67 part 2: the active-run lock is the flock-atomic guard+claim ──────────────────
# (a) A live AGENT claim (owner=agent, fresh heartbeat — TTL-live even with a dead PID)
#     is the PRIMARY guard cron respects: a new run backs off, item stays waiting.
setup_repo
printf 'human_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "blocked by agent" --p0 >/dev/null; bash "$DEPUTY" list >/dev/null
mkdir -p "$DEPUTY_ROOT/.deputy/active-run.lock"
printf '%s\n' 999999 > "$DEPUTY_ROOT/.deputy/active-run.lock/pid"        # dead PID
printf 'x\n'         > "$DEPUTY_ROOT/.deputy/active-run.lock/start_time"
printf 'agent\n'     > "$DEPUTY_ROOT/.deputy/active-run.lock/owner"
printf 'agent work\n'> "$DEPUTY_ROOT/.deputy/active-run.lock/item"
printf '%s\n' "$(date +%s)" > "$DEPUTY_ROOT/.deputy/active-run.lock/heartbeat"   # fresh
DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once >/dev/null 2>&1 || true
assert_contains "$(bash "$DEPUTY" list)" "[P0]" "#67: live AGENT claim (TTL) blocks a new cron run"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" "#67: blocked run wrote no claim"

# (b) _active_run_acquire is an atomic mutex: within one live owner, the 2nd acquire
#     backs off with rc 3 (sees the lock live), confirming guard+claim is serialized.
setup_repo
out="$(bash -c 'source "'"$DEPUTY"'"; r1=0; _active_run_acquire a run >/dev/null 2>&1 || r1=$?; r2=0; _active_run_acquire b run >/dev/null 2>&1 || r2=$?; echo "$r1 $r2"')"
assert_eq "$out" "0 3" "#67: second _active_run_acquire backs off (atomic flock+mkdir mutex)"
