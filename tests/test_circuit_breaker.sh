#!/usr/bin/env bash
# #67: startup-crash circuit-breaker — a worker that dies at spawn before creating a
# waypoint ledger is retried, then SURFACED after startup_fail_strikes (default 3)
# consecutive no-progress crashes, instead of respawning forever.
source "$(dirname "$0")/lib.sh"
setup_repo
printf 'human_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"   # deterministic: no session backoff

# mock orchestrator that always crashes at spawn (exits 1; never runs `deputy start`)
ORCH="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 1\n' > "$ORCH"; chmod +x "$ORCH"
run_once() { DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
             bash "$DEPUTY" run --once >/dev/null 2>&1 || true; }

bash "$DEPUTY" add "crash-loop item" --p0 >/dev/null
bash "$DEPUTY" list >/dev/null

# ticks 1 & 2: crash → reverted to waiting (retried), under the 3-strike limit
run_once
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|" "tick 1: crash → reverted to waiting (retry)"
run_once
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|" "tick 2: still retrying (under strike limit)"

# tick 3: 3rd consecutive crash → circuit opens → surfaced (not waiting, not respawned)
run_once
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "surfaced|P0|"      "tick 3: circuit-breaker trips → item surfaced"
assert_contains "$out" "crash-loop item"   "tick 3: surfaced item description preserved"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/.spawnfail-* 2>/dev/null | wc -l | tr -d ' ')" "0" "breaker counter reset after trip"
assert_contains "$(cat "$DEPUTY_ROOT"/.deputy/questions/*.md 2>/dev/null)" "startup-crash circuit-breaker" "trip writes a questions note for the human"

# tick 4: a surfaced item is NOT re-picked → loop is broken (stays surfaced)
run_once
assert_contains "$(bash "$DEPUTY" list)" "surfaced|P0|" "tick 4: surfaced item not respawned"

# configurable threshold: startup_fail_strikes=1 trips on the first crash
setup_repo
printf 'human_backoff=0\nstartup_fail_strikes=1\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "fast-trip item" --p0 >/dev/null
bash "$DEPUTY" list >/dev/null
run_once
assert_contains "$(bash "$DEPUTY" list)" "surfaced|P0|" "startup_fail_strikes=1: trips on first crash"

rm -f "$ORCH"
