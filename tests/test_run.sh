#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" add "do a thing" --p0

# Mock orchestrator: receives the item line as $1; marks it done.
ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"
assert_contains "$(bash "$DEPUTY" list)" "done|P0|do a thing" "run drove orchestrator to done"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" "no stale claim left"

# Nothing waiting -> run is a clean no-op
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "run no-op exits 0"

# claude unavailable -> run reschedules (no crash) and leaves item waiting
setup_repo
bash "$DEPUTY" add "later" --p1
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="gemini" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "run exits 0 when claude unavailable"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|later" "item stays waiting when claude down"

rm -f "$ORCH"
