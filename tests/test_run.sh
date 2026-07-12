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
assert_contains "$(bash "$DEPUTY" list)" "+[#"          "run drove orchestrator to done"
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
assert_contains "$(bash "$DEPUTY" list)" "[P1]"        "item stays waiting when claude down"
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
assert_eq "$(bash "$DEPUTY" list | grep -c '^\[#')" "2" "both items remain waiting (first reverted, second never started)"
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
assert_eq "$(bash "$DEPUTY" list | grep -c '^+\[#')" "1" "max_items=1 processes exactly one item"
assert_contains "$(bash "$DEPUTY" list)" "[P0]"        "the second item is left for the next cycle"
assert_contains "$(bash "$DEPUTY" list)" "two"         "item 'two' is left for the next cycle"

# --- #60: max_items defaults to 1 when unset (one tick = one item) ---
setup_repo
bash "$DEPUTY" add "a" --p0; bash "$DEPUTY" add "b" --p0
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c '^+\[#')" "1" "unset max_items defaults to 1 (not unlimited)"

# --- #60: max_items=0 clamps to 1 (NO unbounded drain) ---
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'max_items=0\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "x" --p0; bash "$DEPUTY" add "y" --p0; bash "$DEPUTY" add "z" --p0
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c '^+\[#')" "1" "max_items=0 clamps to 1 (no unbounded drain)"

# --- #60: an explicit max_items=N still processes up to N ---
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'max_items=2\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "p" --p0; bash "$DEPUTY" add "q" --p0; bash "$DEPUTY" add "r" --p0
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c '^+\[#')" "2" "explicit max_items=2 processes up to 2"

rm -f "$ORCH"

# --- #60: cmd_run exports DEPUTY_HEADLESS to the orchestrator (1 = headless/no-TTY) ---
setup_repo
HE="$(mktemp)"
cat > "$HE" <<EOS
#!/usr/bin/env bash
printf '%s' "\${DEPUTY_HEADLESS:-unset}" > "$DEPUTY_ROOT/.hl"
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1
EOS
chmod +x "$HE"
bash "$DEPUTY" add "hl item" --p0
DEPUTY_ORCHESTRATOR_CMD="$HE" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once >/dev/null 2>&1
assert_eq "$(cat "$DEPUTY_ROOT/.hl" 2>/dev/null)" "1" "cmd_run exports DEPUTY_HEADLESS=1 to a headless (no-TTY) worker"
rm -f "$HE"
