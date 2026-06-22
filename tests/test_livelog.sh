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
