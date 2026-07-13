#!/usr/bin/env bash
# tests/test_watchdog.sh — #87: runner watchdog kills a no-waypoint-progress worker and
# surfaces the item. Uses the DEPUTY_WATCHDOG_SECS/POLL_SECS/GRACE_SECS test seams so a
# real (minute-scale) cap isn't needed.
source "$(dirname "$0")/lib.sh"

# A) TRIP: a hanging worker (never commits a waypoint) is killed + the item is surfaced.
setup_repo
HANG="$(mktemp)"; printf '#!/usr/bin/env bash\nsleep 60\n' > "$HANG"; chmod +x "$HANG"
bash "$DEPUTY" add "hang item" --p0 >/dev/null
t0=$(date +%s)
DEPUTY_WATCHDOG_SECS=2 DEPUTY_WATCHDOG_POLL_SECS=1 DEPUTY_WATCHDOG_GRACE_SECS=1 \
  DEPUTY_ORCHESTRATOR_CMD="$HANG" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  timeout 30 bash "$DEPUTY" run --once >/dev/null 2>&1
t1=$(date +%s)
assert_eq "$([[ $((t1-t0)) -lt 25 ]] && echo yes || echo no)" "yes" "watchdog trip: run returns (worker killed) long before the 60s hang"
assert_contains "$(bash "$DEPUTY" list surfaced)" "hang item" "watchdog trip: the hung item was surfaced"
rm -f "$HANG"

# B) NO FALSE TRIP: a fast worker (finishes before the cap) completes normally, not surfaced.
setup_repo
FAST="$(mktemp)"; printf '#!/usr/bin/env bash\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$FAST"; chmod +x "$FAST"
bash "$DEPUTY" add "fast item" --p0 >/dev/null
DEPUTY_WATCHDOG_SECS=5 DEPUTY_WATCHDOG_POLL_SECS=1 \
  DEPUTY_ORCHESTRATOR_CMD="$FAST" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  timeout 30 bash "$DEPUTY" run --once >/dev/null 2>&1
sout="$(bash "$DEPUTY" list surfaced)"
if printf '%s' "$sout" | grep -q "fast item"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: watchdog surfaced a fast-completing worker (false trip)\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi

# C) DISABLED (watchdog_mins=0): the disable path is taken; a fast worker still completes.
setup_repo
echo 'watchdog_mins=0' >> "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "disabled item" --p0 >/dev/null
FAST2="$(mktemp)"; printf '#!/usr/bin/env bash\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$FAST2"; chmod +x "$FAST2"
DEPUTY_WATCHDOG_SECS=2 DEPUTY_WATCHDOG_POLL_SECS=1 \
  DEPUTY_ORCHESTRATOR_CMD="$FAST2" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  timeout 30 bash "$DEPUTY" run --once >/dev/null 2>&1
if printf '%s' "$(bash "$DEPUTY" list surfaced)" | grep -q "disabled item"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: disabled watchdog surfaced an item\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi
rm -f "$FAST" "$FAST2"

# D) documented in help
assert_contains "$(bash "$DEPUTY" help --full 2>&1)" "watchdog_mins" "watchdog_mins documented in deputy help --full"
