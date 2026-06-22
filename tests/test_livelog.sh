#!/usr/bin/env bash
# tests/test_livelog.sh — #63: stable per-item live log archived to .deputy/logs/<id>.log.
source "$(dirname "$0")/lib.sh"
ORCH="$(mktemp)"
printf '#!/usr/bin/env bash\necho "WORKER-LOG-MARKER-63"\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$ORCH"; chmod +x "$ORCH"

# 1: a headless run streams to .deputy/run-<id>.log and archives it to .deputy/logs/<id>.log
setup_repo
bash "$DEPUTY" add "livelog item" --p0 >/dev/null
id="$(bash "$DEPUTY" list | grep -F 'livelog item' | cut -d'|' -f3)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once >/dev/null 2>&1
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/logs/$id.log" && echo yes || echo no)" "yes" "run archives log to .deputy/logs/<id>.log"
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/logs/$id.log" 2>/dev/null)" "WORKER-LOG-MARKER-63" "archived log holds the worker output"
assert_eq "$(test -e "$DEPUTY_ROOT/.deputy/run-$id.log" && echo present || echo gone)" "gone" "live run-<id>.log is archived (moved), not left behind"

# 2: the QUOTA branch (rc!=0 + "hit your limit") also archives the live log
setup_repo
QORCH="$(mktemp)"; printf '#!/usr/bin/env bash\necho "You have hit your limit; resets 9pm"\nexit 1\n' > "$QORCH"; chmod +x "$QORCH"
bash "$DEPUTY" add "quota item" --p0 >/dev/null
qid="$(bash "$DEPUTY" list | grep -F 'quota item' | cut -d'|' -f3)"
DEPUTY_ORCHESTRATOR_CMD="$QORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once >/dev/null 2>&1
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/logs/$qid.log" && echo yes || echo no)" "yes" "quota branch archives the live log to logs/<id>.log"
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/logs/$qid.log" 2>/dev/null)" "hit your limit" "archived quota log holds the worker output"
assert_eq "$(test -e "$DEPUTY_ROOT/.deputy/run-$qid.log" && echo present || echo gone)" "gone" "no stray live log after quota skip"
rm -f "$QORCH"

rm -f "$ORCH"

# 3: 'deputy watch' with no active run -> friendly message + exit 0
setup_repo
out="$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$DEPUTY" watch 2>&1; echo "rc=$?")"
assert_contains "$out" "no worker is running" "watch (idle) prints a friendly message"
assert_contains "$out" "rc=0" "watch (idle) exits 0"

# 4: 'deputy watch' streams the running worker's log, then exits when the run pid ends
setup_repo
sleep 3 & spid=$!
mkdir -p "$DEPUTY_ROOT/.deputy/active-run.lock"
printf '%s\n' "$spid" > "$DEPUTY_ROOT/.deputy/active-run.lock/pid"
printf 'run\n'        > "$DEPUTY_ROOT/.deputy/active-run.lock/owner"
printf '@[P0][#77] watch target\n' > "$DEPUTY_ROOT/.deputy/active-run.lock/item"   # no start_time -> liveness = kill -0
printf 'STREAM-LINE-63\n' > "$DEPUTY_ROOT/.deputy/run-77.log"
out="$(timeout 8 env DEPUTY_ROOT="$DEPUTY_ROOT" bash "$DEPUTY" watch 2>&1)"
assert_contains "$out" "STREAM-LINE-63"        "watch streams the running worker's live log"
assert_contains "$out" "ended — output archived" "watch reports the archived path when the run ends"
kill "$spid" 2>/dev/null || true
