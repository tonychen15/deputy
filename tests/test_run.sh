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
assert_contains "$(bash "$DEPUTY" list)" "done|P0|"     "run drove orchestrator to done"
assert_contains "$(bash "$DEPUTY" list)" "do a thing"   "run: item description preserved"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" "no stale claim left"

# Nothing waiting -> run is a clean no-op
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "run no-op exits 0"

# claude unavailable -> run reschedules (no crash) and leaves item waiting
setup_repo
bash "$DEPUTY" add "later" --p1
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="gemini" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "run exits 0 when claude unavailable"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|" "item stays waiting when claude down"
assert_contains "$(bash "$DEPUTY" list)" "later"       "item 'later' stays waiting"

# --- session limit (quota) stops the cycle, reverts item, uses always-on heartbeat for retry ---
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'max_items=0\n' > "$DEPUTY_ROOT/.deputy/config"
# Opt in to autonomous mode.
: > "$DEPUTY_ROOT/.deputy/cron.enabled"
bash "$DEPUTY" add "first job" --p0
bash "$DEPUTY" add "second job" --p0
LIMIT="$(mktemp)"
cat > "$LIMIT" <<'EOF'
#!/usr/bin/env bash
echo "You have hit your limit; resets 11pm"
exit 1
EOF
chmod +x "$LIMIT"
STORE="$(mktemp)"; : > "$STORE"; FAKE="$(mktemp)"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-l" ]] && { cat "$STORE"; exit 0; }
[[ "\${1:-}" == "-" ]] && { cat > "$STORE"; exit 0; }
exit 0
EOF
chmod +x "$FAKE"
out="$(DEPUTY_ORCHESTRATOR_CMD="$LIMIT" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB="$FAKE" bash "$DEPUTY" run 2>&1)"
assert_contains "$out" "session limit" "run reports the session limit"
assert_eq "$(bash "$DEPUTY" list | grep -c 'waiting|P0')" "2" "both items remain waiting (first reverted, second never started)"
# Always-on model: do NOT reschedule the shared cron line for quota.
# The fixed heartbeat retries; quota is a per-task skip (no cron line written).
assert_eq "$(grep -c 'deputy' "$STORE")" "0" "always-on: session limit does NOT reschedule cron (heartbeat handles retry)"
rm -f "$LIMIT" "$STORE" "$FAKE"

# --- max_items caps items per cycle ---
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'max_items=1\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "one" --p0
bash "$DEPUTY" add "two" --p0
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c 'done|P0')" "1" "max_items=1 processes exactly one item"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|" "the second item is left for the next cycle"
assert_contains "$(bash "$DEPUTY" list)" "two"         "item 'two' is left for the next cycle"

rm -f "$ORCH"
