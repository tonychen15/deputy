#!/usr/bin/env bash
# Verifies cmd_run prints the remaining waiting/paused queue after each item it
# finishes: a readable, priority-sorted (FIFO on ties) list, or a "queue empty"
# line once nothing runnable remains.
source "$(dirname "$0")/lib.sh"

# Mock orchestrator: marks the item line it receives ($1) done.
ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

# --- list shown after a completion, then "queue empty" when drained ---
setup_repo
bash "$DEPUTY" add "first task"  --p0
bash "$DEPUTY" add "second task" --p1
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>&1)"
assert_contains "$out" "Waiting tasks (1):"          "after first completion, one task remains"
assert_contains "$out" "second task"                 "remaining task is listed by description"
assert_contains "$out" "Waiting tasks: queue empty." "queue-empty shown once drained"

# --- priority order with FIFO tie-break matches cmd_pick ---
# File order: alpha(P2) beta(P0) gamma(P1) delta(P2). beta(P0) runs first; the
# first list after its completion must be gamma(P1), then alpha(P2), then delta(P2).
setup_repo
bash "$DEPUTY" add "alpha" --p2
bash "$DEPUTY" add "beta"  --p0
bash "$DEPUTY" add "gamma" --p1
bash "$DEPUTY" add "delta" --p2
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>&1)"
# Grab the first "Waiting tasks (3):" block (the three survivors of beta).
block="$(printf '%s\n' "$out" | awk '/^Waiting tasks \(3\):/{f=1;next} f&&/^Waiting tasks/{exit} f{print}')"
gpos="$(printf '%s\n' "$block" | grep -n 'gamma' | head -1 | cut -d: -f1)"
apos="$(printf '%s\n' "$block" | grep -n 'alpha' | head -1 | cut -d: -f1)"
dpos="$(printf '%s\n' "$block" | grep -n 'delta' | head -1 | cut -d: -f1)"
assert_eq "$([[ -n "$gpos" && -n "$apos" && "$gpos" -lt "$apos" ]] && echo ok)" "ok" "P1 gamma before P2 alpha"
assert_eq "$([[ -n "$apos" && -n "$dpos" && "$apos" -lt "$dpos" ]] && echo ok)" "ok" "P2 alpha (earlier) before P2 delta (FIFO tie)"
assert_contains "$block" "[#" "list shows item id tags"

# --- nothing runnable: --once no-op still does not crash, prints queue-empty path only on completion ---
# (A no-op run never completes an item, so it prints nothing; assert it stays clean.)
setup_repo
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "empty-backlog run exits 0"

rm -f "$ORCH"
