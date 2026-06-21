#!/usr/bin/env bash
# tests/test_reap.sh — #58: a headless worker's leaked process subtree is reaped on completion.
source "$(dirname "$0")/lib.sh"

CF="$(mktemp)"; ORCH="$(mktemp)"
# Mock worker: leak a background child (inherits the worker's process group), record its
# pid, mark the item done, exit (does NOT wait for the child).
cat > "$ORCH" <<EOS
#!/usr/bin/env bash
sleep 30 &
echo \$! > "$CF"
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1
EOS
chmod +x "$ORCH"

setup_repo
bash "$DEPUTY" add "reap me" --p0 >/dev/null
DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once >/tmp/reap_out.txt 2>/tmp/reap_err.txt
child="$(cat "$CF" 2>/dev/null)"
# give SIGTERM a moment to land
for _i in 1 2 3 4 5; do kill -0 "$child" 2>/dev/null || break; sleep 0.3; done
assert_eq "$(kill -0 "$child" 2>/dev/null && echo alive || echo dead)" "dead" \
  "#58: the headless worker's leaked child is reaped on completion"
kill "$child" 2>/dev/null   # cleanup if it somehow survived

# no set -m job-control noise leaked into the run's output or stderr (cron.log path).
assert_eq "$(grep -cE '^\[[0-9]+\]\+?|Terminated|^\[1\]' /tmp/reap_out.txt /tmp/reap_err.txt 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" "0" \
  "#58: no job-control noise in the run output/stderr"

# the item still completes through the reaping path (rc/flow intact).
assert_contains "$(bash "$DEPUTY" list)" "done|P0" "#58: the item still completes through the reaping path"

rm -f "$ORCH" "$CF"
